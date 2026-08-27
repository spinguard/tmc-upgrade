#!/usr/bin/env bash
# Collect evidence for the TMC 1.4.5 NoUpgradeVersions / vsphereoptions rewrite-loop case.
#
# RUN ON THE SUPERVISOR CONTROL PLANE NODE (needs /etc/kubernetes/admin.conf).
#
#   ./collect-tmc-options-evidence.sh before     # capture broken state  <-- DO THIS FIRST
#   ./collect-tmc-options-evidence.sh restart    # restart the retriever
#   ./collect-tmc-options-evidence.sh after      # capture post-restart state
#
# Read `options` BEFORE restarting. A restart may clear the loop and destroy
# the evidence of what the persisted option set actually looked like.

set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
NS=svc-tmc-c9
OBJ=vsphereoptions/options
PHASE="${1:-}"
OUT="${OUT:-/tmp/tmc-evidence}"
mkdir -p "$OUT"

log(){ printf '\n=== %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

if [[ -z "$PHASE" || ! "$PHASE" =~ ^(before|restart|after)$ ]]; then
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

# --------------------------------------------------------------------------
if [[ "$PHASE" == restart ]]; then
  log "restarting vsphere-resource-retriever"
  kubectl -n "$NS" rollout restart deployment/vsphere-resource-retriever
  kubectl -n "$NS" rollout status deployment/vsphere-resource-retriever --timeout=180s
  echo "Now wait ~3 minutes for it to settle, then run: $0 after"
  exit 0
fi

P="$OUT/$PHASE"
mkdir -p "$P"
log "phase=$PHASE  ->  $P   ($(date -u +%Y-%m-%dT%H:%M:%SZ))"

# --- 1. THE OBJECT WE COULD NEVER READ ------------------------------------
log "1. dumping $OBJ"
if kubectl -n "$NS" get "$OBJ" -o yaml > "$P/options.yaml" 2>"$P/options.err"; then
  echo "  wrote $P/options.yaml ($(wc -c < "$P/options.yaml") bytes)"
else
  echo "  FAILED: $(cat "$P/options.err")"
fi

log "2. does the persisted option set contain 1.36?  (THE key question)"
if [[ -s "$P/options.yaml" ]]; then
  for v in 1.34 1.35 1.36; do
    printf '   v%-5s occurrences: %s\n' "$v" "$(grep -c "$v" "$P/options.yaml")"
  done
  echo "   distinct k8s versions present:"
  grep -oE 'v1\.3[0-9]+\.[0-9]+[+-][A-Za-z0-9.+-]*' "$P/options.yaml" \
    | sort -u | sed 's/^/     /' | tee "$P/versions-in-options.txt"
fi

# --- 3. IS THE OBJECT ACTUALLY BEING REWRITTEN? ---------------------------
# resourceVersion delta over 10s == number of persisted writes. This is the
# cleanest possible proof of the loop, and was not obtainable without admin.
log "3. resourceVersion churn over 10s (delta = persisted writes)"
rv1=$(kubectl -n "$NS" get "$OBJ" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
gen1=$(kubectl -n "$NS" get "$OBJ" -o jsonpath='{.metadata.generation}' 2>/dev/null)
sleep 10
rv2=$(kubectl -n "$NS" get "$OBJ" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
gen2=$(kubectl -n "$NS" get "$OBJ" -o jsonpath='{.metadata.generation}' 2>/dev/null)
{
  echo "resourceVersion: $rv1 -> $rv2   (delta $(( ${rv2:-0} - ${rv1:-0} )) over 10s)"
  echo "generation:      $gen1 -> $gen2   (delta $(( ${gen2:-0} - ${gen1:-0} )))"
} | tee "$P/rv-churn.txt" | sed 's/^/   /'
echo "   NOTE: resourceVersion is an etcd-global counter, so the delta is an upper"
echo "         bound on writes to this object. generation delta is object-specific."

# --- 4. DOES THE CONTENT ACTUALLY DIFFER BETWEEN WRITES? ------------------
# If two consecutive reads are byte-identical apart from metadata, the
# controller is rewriting identical content -> non-convergence is confirmed.
log "4. content-identical check (strip volatile metadata, compare 2 reads 5s apart)"
strip(){ grep -vE '^\s*(resourceVersion|generation|managedFields|lastTransitionTime|time):' ; }
kubectl -n "$NS" get "$OBJ" -o yaml 2>/dev/null | strip > "$P/snap1.yaml"
sleep 5
kubectl -n "$NS" get "$OBJ" -o yaml 2>/dev/null | strip > "$P/snap2.yaml"
if diff -q "$P/snap1.yaml" "$P/snap2.yaml" >/dev/null 2>&1; then
  echo "   IDENTICAL content across writes -> controller rewrites unchanged data (defect)"
  echo "identical" > "$P/content-verdict.txt"
else
  echo "   content DIFFERS between reads -> capturing the diff (shows what oscillates)"
  diff -u "$P/snap1.yaml" "$P/snap2.yaml" > "$P/content-diff.txt" 2>&1
  head -40 "$P/content-diff.txt" | sed 's/^/     /'
  echo "differs" > "$P/content-verdict.txt"
fi

# --- 5. RATES ------------------------------------------------------------
log "5. loop rates"
{
  echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "conflicts/15m:            $(kubectl -n "$NS" logs deploy/vsphere-resource-retriever --since=15m 2>/dev/null | grep -c 'object has been modified')"
  echo "retriever lines/60s:      $(kubectl -n "$NS" logs deploy/vsphere-resource-retriever --since=60s 2>/dev/null | wc -l | tr -d ' ')"
  echo "VsphereOption events/60s: $(kubectl -n "$NS" logs deploy/sync-agent --since=60s 2>/dev/null | grep -c '"kind":"VsphereOption"')"
  echo "Node events/60s:          $(kubectl -n "$NS" logs deploy/sync-agent --since=60s 2>/dev/null | grep -c '"kind":"Node"')"
  echo "retriever uptime:         $(kubectl -n "$NS" get pod -l app=vsphere-resource-retriever --no-headers 2>/dev/null | awk '{print $4, $5}')"
} | tee "$P/rates.txt" | sed 's/^/   /'

# --- 6. LOGS + OWNERSHIP -------------------------------------------------
log "6. saving logs and object ownership"
kubectl -n "$NS" logs deploy/vsphere-resource-retriever --since=15m > "$P/retriever.log" 2>&1
kubectl -n "$NS" logs deploy/sync-agent --since=5m           > "$P/sync-agent.log" 2>&1
kubectl -n "$NS" get "$OBJ" -o jsonpath='{.metadata.managedFields}' 2>/dev/null \
  | tr ',' '\n' | grep -iE 'manager|operation|time' > "$P/managed-fields.txt" 2>&1
echo "   wrote retriever.log, sync-agent.log, managed-fields.txt"
echo "   (managedFields shows WHICH controllers write this object — if more than"
echo "    one manager appears, that is a second writer fighting the renderer)"

log "done — phase '$PHASE' collected under $P"
[[ "$PHASE" == before ]] && echo "Next: $0 restart"

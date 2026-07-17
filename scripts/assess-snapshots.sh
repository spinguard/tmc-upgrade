#!/usr/bin/env bash
#
# assess-snapshots.sh [kube-context ...]
#
# Reads the before/after snapshots captured by snapshot-cluster.sh and emits a
# markdown post-upgrade assessment: one pass/review/finding row per dimension per
# cluster, plus an overall verdict. With no context argument it assesses every
# cluster under the snapshot root that has BOTH a before/ and an after/ dir.
#
# Output root defaults to ./snapshots (override with env SNAPSHOT_ROOT). Report
# is written to stdout — redirect where you like:
#
#   scripts/assess-snapshots.sh > snapshots/upgrade-assessment-auto.md
#
# (snapshots/upgrade-assessment.md is the curated, hand-reviewed narrative; keep
# the machine-generated report under a distinct name so it doesn't clobber it.)
#
# Deterministic and rule-based (no LLM). It encodes the "What each diff should
# show" expectations from README section 4.3. Judgment calls it cannot make
# (novel findings) are surfaced as REVIEW rows for a human, never silently
# passed. Best-effort: a missing snapshot file is skipped, not fatal.
#
# Classification:
#   PASS    (ok)  expected state / expected move landed cleanly
#   REVIEW  (rv)  changed or failing in a way a human should eyeball
#                 (includes pre-existing failures — flagged, not blamed on the upgrade)
#   FINDING (!!)  the upgrade appears to have broken something
#
# Companion: snapshot-cluster.sh (capture), diff-snapshots.sh (raw diff).

set -uo pipefail

ROOT="${SNAPSHOT_ROOT:-snapshots}"

# --- normalization -----------------------------------------------------------
# Strip AGE-style duration columns (25h, 176m, 4h45m, 30s, 2d3h) so before/after
# compare on substance, not the clock. Applied symmetrically to both sides, so
# even where it clips a hex digest it preserves equality/inequality — a real
# change still differs; collisions are negligible. Pod-name churn is NOT
# normalized here on purpose: the files these checks diff carry package/node/CRD
# names (stable), never pod names — those are handled via digest extraction.
norm() {
  sed -E 's/[0-9]+(\.[0-9]+)?(ms|d|h|m|s)([0-9]+(ms|d|h|m|s))*/<age>/g'
}

# Normalized unified diff of two files (empty output == equivalent). -w ignores
# whitespace so column-width shifts (a wider AGE value re-pads the whole table)
# don't register as content changes.
ndiff() { diff -w <(norm <"$1" 2>/dev/null) <(norm <"$2" 2>/dev/null) 2>/dev/null; }

# Collapse a multi-line blob to a single, truncated table-cell string.
oneline() {
  tr '\n' ';' | sed -E 's/;+/; /g; s/^ *//; s/[; ]+$//' | cut -c1-160
}

# --- per-run counters (reset per cluster) ------------------------------------
n_pass=0; n_review=0; n_finding=0

emoji() { case "$1" in ok) printf '✅';; rv) printf '⚠️';; '!!') printf '❌';; esac; }

# row <kind:ok|rv|!!> <check> <detail>
row() {
  case "$1" in
    ok) n_pass=$((n_pass+1));;
    rv) n_review=$((n_review+1));;
    '!!') n_finding=$((n_finding+1));;
  esac
  printf '| %s | %s %s | %s |\n' "$2" "$(emoji "$1")" "$(kind_word "$1")" "${3:-—}"
}
kind_word() { case "$1" in ok) printf PASS;; rv) printf REVIEW;; '!!') printf FINDING;; esac; }

exists() { [ -s "$1" ]; }

# --- the checks --------------------------------------------------------------
assess_ctx() {
  local ctx="$1" B="$ROOT/$1/before" A="$ROOT/$1/after"
  n_pass=0; n_review=0; n_finding=0

  printf '\n## Cluster `%s`\n\n' "$ctx"
  printf '| Check | Result | Detail |\n|---|---|---|\n'

  # 1. Tanzu repositories & PackageRepository reconcile ------------------------
  if exists "$A/repositories.txt" || exists "$A/pkgr.txt"; then
    local rfail moves
    rfail=$(grep -hiE 'reconcile (failed|failing)|NOT_FOUND|error' "$A/repositories.txt" "$A/pkgr.txt" 2>/dev/null)
    moves=$(ndiff "$B/repositories.txt" "$A/repositories.txt" | grep '^>' | sed 's/^> *//' | grep -viE '^[[:space:]]*$')
    if [ -n "$rfail" ]; then
      row '!!' 'repositories / pkgr reconcile' "not succeeded: $(printf '%s' "$rfail" | oneline)"
    elif [ -n "$moves" ]; then
      row 'ok' 'repositories (version move)' "$(printf '%s' "$moves" | oneline)"
    else
      row 'ok' 'repositories' 'reconcile succeeded; no URL/version change'
    fi
  fi

  # 1b. PackageRepository image/tag & reconcile (the `describe pkgr` substance) --
  # Guest clusters: the 1.4.4 upgrade repoints tanzu-standard at the TMC-SM
  # mirrored catalog, so the imgpkgBundle image/tag is expected to move — but the
  # repo must still reconcile. A non-succeeded status here is a real finding.
  if exists "$A/pkgr-detail.txt"; then
    local prfail prmove
    prfail=$(grep -v 'status=Reconcile succeeded' "$A/pkgr-detail.txt" | grep -viE '^[[:space:]]*$')
    prmove=$(ndiff "$B/pkgr-detail.txt" "$A/pkgr-detail.txt" | grep '^>' | sed 's/^> *//' | grep -viE '^[[:space:]]*$')
    if [ -n "$prfail" ]; then
      row '!!' 'PackageRepository reconcile (pkgr image/status)' "not succeeded: $(printf '%s' "$prfail" | oneline)"
    elif [ -n "$prmove" ]; then
      row 'ok' 'PackageRepository image/tag (pkgr)' "reconciled; image moved (expected 1.4.4 catalog repoint): $(printf '%s' "$prmove" | oneline)"
    else
      row 'ok' 'PackageRepository image/tag (pkgr)' 'reconciled; no image/tag change'
    fi
  fi

  # 1c. Offered package catalog (tkg -> vks offerings swap) -------------------
  if exists "$A/pkg-catalog.txt"; then
    local newpkgs droppedpkgs
    newpkgs=$(comm -13 <(sort -u "$B/pkg-catalog.txt" 2>/dev/null) <(sort -u "$A/pkg-catalog.txt") | grep -viE '^[[:space:]]*$')
    droppedpkgs=$(comm -23 <(sort -u "$B/pkg-catalog.txt" 2>/dev/null) <(sort -u "$A/pkg-catalog.txt") | grep -viE '^[[:space:]]*$')
    if [ -z "$newpkgs" ] && [ -z "$droppedpkgs" ]; then
      row 'ok' 'package catalog (offerings)' 'unchanged'
    else
      row 'rv' 'package catalog (offerings)' "changed — confirm vks/tkg swap intended: +[$(printf '%s' "$newpkgs" | oneline)] -[$(printf '%s' "$droppedpkgs" | oneline)]"
    fi
  fi

  # 2. PackageInstall reconcile status ----------------------------------------
  if exists "$A/pkgi-status.txt"; then
    local notok
    notok=$(awk 'NR>1 && NF' "$A/pkgi-status.txt" | grep -ivE 'Reconcile succeeded' )
    if [ -n "$notok" ]; then
      # was it already failing before? then it's pre-existing, not the upgrade
      local was
      was=$(awk 'NR>1 && NF' "$B/pkgi-status.txt" 2>/dev/null | grep -ivE 'Reconcile succeeded')
      if [ -n "$was" ]; then
        row 'rv' 'PackageInstall reconcile' "not-succeeded (also before upgrade): $(printf '%s' "$notok" | oneline)"
      else
        row '!!' 'PackageInstall reconcile' "newly not-succeeded: $(printf '%s' "$notok" | oneline)"
      fi
    else
      row 'ok' 'PackageInstall reconcile' 'all Reconcile succeeded'
    fi
  fi

  # 3. Discovery health — the literal symptom of the CD break -----------------
  if [ -f "$A/api-resources.err" ]; then
    if exists "$A/api-resources.err"; then
      row '!!' 'discovery health (api-resources.err)' "non-empty: $(oneline <"$A/api-resources.err")"
    else
      row 'ok' 'discovery health (api-resources.err)' 'empty — all API groups enumerable'
    fi
  fi

  # 4. APIService availability -------------------------------------------------
  if exists "$A/apiservices.txt"; then
    local fa fb
    fa=$(awk 'NR>1 && $3=="False"{print $1}' "$A/apiservices.txt")
    fb=$(awk 'NR>1 && $3=="False"{print $1}' "$B/apiservices.txt" 2>/dev/null)
    if [ -z "$fa" ]; then
      row 'ok' 'APIServices Available' 'none Available=False'
    elif [ "$fa" = "$fb" ]; then
      row 'rv' 'APIServices Available' "Available=False (also before): $(printf '%s' "$fa" | oneline)"
    else
      row '!!' 'APIServices Available' "newly Available=False: $(printf '%s' "$fa" | oneline)"
    fi
  fi

  # 5. CRD served/storage versions (the Flux mechanism, generalized) ----------
  if exists "$A/crd-versions.txt"; then
    local crd
    crd=$(ndiff "$B/crd-versions.txt" "$A/crd-versions.txt" | grep '^>' | sed 's/^> *//' | cut -d: -f1)
    if [ -z "$crd" ]; then
      row 'ok' 'CRD served/storage versions' 'no change'
    else
      row 'rv' 'CRD served/storage versions' "changed (confirm storage-version safe): $(printf '%s' "$crd" | oneline)"
    fi
  fi

  # 6. PackageInstall constraint drift ----------------------------------------
  if exists "$A/pkgi-constraints.txt"; then
    local con
    con=$(ndiff "$B/pkgi-constraints.txt" "$A/pkgi-constraints.txt" | grep '^>' | sed 's/^> *//')
    if [ -z "$con" ]; then
      row 'ok' 'PackageInstall constraints' 'unchanged'
    else
      row 'rv' 'PackageInstall constraints' "changed: $(printf '%s' "$con" | oneline)"
    fi
  fi

  # 7. Node states -------------------------------------------------------------
  if exists "$A/nodes.txt"; then
    local nr ndelta
    nr=$(awk 'NR>1 && $2!~"Ready"{print $1" ("$2")"}' "$A/nodes.txt")
    ndelta=$(ndiff "$B/nodes.txt" "$A/nodes.txt")
    if [ -n "$nr" ]; then
      row '!!' 'node states' "not Ready: $(printf '%s' "$nr" | oneline)"
    elif [ -n "$ndelta" ]; then
      row 'rv' 'node states' 'all Ready; version/roster changed (TKR/kubelet roll?) — verify expected'
    else
      row 'ok' 'node states' 'all Ready; no change'
    fi
  fi

  # 8. Flux CR reconcile truth -------------------------------------------------
  if exists "$A/flux-resources.txt"; then
    local ba aa afalse
    ba=$(grep -icE '\bFalse\b' "$B/flux-resources.txt" 2>/dev/null); ba=${ba:-0}
    aa=$(grep -icE '\bFalse\b' "$A/flux-resources.txt"); aa=${aa:-0}
    afalse=$(grep -iE '\bFalse\b' "$A/flux-resources.txt" | awk '{print $2}')
    if [ "$aa" -eq 0 ]; then
      row 'ok' 'Flux CR reconcile' 'all Ready=True'
    elif [ "$aa" -le "$ba" ]; then
      row 'rv' 'Flux CR reconcile' "$aa not-Ready (<= $ba before; pre-existing): $(printf '%s' "$afalse" | oneline)"
    else
      row '!!' 'Flux CR reconcile' "$aa not-Ready (was $ba before): $(printf '%s' "$afalse" | oneline)"
    fi
  fi

  # 9. Admission webhooks ------------------------------------------------------
  if exists "$A/webhooks.txt"; then
    local wd
    wd=$(diff -w <(awk 'NR>1{print $1}' "$B/webhooks.txt" 2>/dev/null | sort) \
                 <(awk 'NR>1{print $1}' "$A/webhooks.txt" | sort))
    if [ -z "$wd" ]; then
      row 'ok' 'admission webhooks' 'name set unchanged'
    else
      row 'rv' 'admission webhooks' "set changed: $(printf '%s' "$wd" | grep -E '^[<>]' | oneline)"
    fi
  fi

  # 10. Named component version matrix ----------------------------------------
  if exists "$A/component-versions.txt"; then
    local cv
    cv=$(diff -w <(grep -vE '^# Component version matrix' "$B/component-versions.txt" 2>/dev/null) \
                 <(grep -vE '^# Component version matrix' "$A/component-versions.txt") \
          | grep '^>' | sed 's/^> *//' | grep -viE '^[[:space:]]*$')
    if [ -z "$cv" ]; then
      row 'ok' 'component versions (cert-mgr/contour/flux/velero)' 'no image/version move'
    else
      row 'rv' 'component versions (cert-mgr/contour/flux/velero)' "moved (confirm vs v2026.1.21 notes): $(printf '%s' "$cv" | oneline)"
    fi
  fi

  # 11. TMC agent roll (informational) ----------------------------------------
  if exists "$A/pod-images.txt"; then
    local newimg
    newimg=$(comm -13 \
      <(grep 'vmware-system-tmc' "$B/pod-images.txt" 2>/dev/null | grep -oE 'sha256:[0-9a-f]+' | sort -u) \
      <(grep 'vmware-system-tmc' "$A/pod-images.txt" | grep -oE 'sha256:[0-9a-f]+' | sort -u) | grep -c .)
    if [ "${newimg:-0}" -gt 0 ]; then
      row 'ok' 'TMC agent images (vmware-system-tmc)' "$newimg new image digest(s) — expected agent roll"
    else
      row 'ok' 'TMC agent images (vmware-system-tmc)' 'no digest change'
    fi
  fi

  # --- per-cluster verdict ---------------------------------------------------
  local verdict
  if   [ "$n_finding" -gt 0 ]; then verdict="❌ **FINDING** — $n_finding finding(s), $n_review to review"
  elif [ "$n_review"  -gt 0 ]; then verdict="⚠️ **REVIEW** — $n_review item(s) to eyeball, no findings"
  else                              verdict="✅ **CLEAN** — all $n_pass checks passed"
  fi
  printf '\n**Verdict (`%s`): %s**\n' "$ctx" "$verdict"

  # roll into the grand total
  g_finding=$((g_finding + n_finding))
  g_review=$((g_review + n_review))
}

# --- driver ------------------------------------------------------------------
contexts=("$@")
if [ "${#contexts[@]}" -eq 0 ]; then
  # auto-discover clusters that have both before/ and after/
  for d in "$ROOT"/*/; do
    c="$(basename "$d")"
    [ -d "$ROOT/$c/before" ] && [ -d "$ROOT/$c/after" ] && contexts+=("$c")
  done
fi

if [ "${#contexts[@]}" -eq 0 ]; then
  echo "no clusters with both before/ and after/ snapshots under '$ROOT'" >&2
  echo "usage: $(basename "$0") [kube-context ...]   (SNAPSHOT_ROOT overrides root)" >&2
  exit 2
fi

g_finding=0; g_review=0

printf '# TMC SM 1.4.2 → 1.4.4 — Post-Upgrade Assessment\n'
printf '\n_Generated %s by `%s` from `%s/<ctx>/{before,after}`. Rule-based; encodes README §4.3._\n' \
  "$(date +%Y-%m-%d)" "$(basename "$0")" "$ROOT"
printf '\nClusters assessed: %s\n' "${contexts[*]}"

for c in "${contexts[@]}"; do
  [ -d "$ROOT/$c/before" ] && [ -d "$ROOT/$c/after" ] || {
    printf '\n## Cluster `%s`\n\n_skipped: missing before/ or after/ snapshot._\n' "$c"; continue; }
  assess_ctx "$c"
done

printf '\n---\n\n## Overall\n\n'
if   [ "$g_finding" -gt 0 ]; then printf '❌ **%d finding(s)** across clusters — investigate before sign-off.\n' "$g_finding"
elif [ "$g_review"  -gt 0 ]; then printf '⚠️ **No findings**, %d item(s) flagged for review.\n' "$g_review"
else                              printf '✅ **Clean** — no findings, nothing flagged for review.\n'
fi

# Exit non-zero only on a real finding, so CI/automation can gate on it.
[ "$g_finding" -eq 0 ]

#!/usr/bin/env bash
#
# snapshot-cluster.sh <before|after> [output-root]
#
# Captures an identical cluster state snapshot for before/after comparison of the
# TMC SM 1.4.2 -> 1.4.4 upgrade. Run with the target cluster's kube-context
# ACTIVE (the TMC SM cluster or a managed guest), once per label. Output goes to
#   <output-root>/<kube-context>/<label>/     (output-root defaults to ./snapshots)
#
# Best-effort by design: a missing CLI or absent resource type is skipped, not
# fatal, so a single run captures whatever the cluster actually has.
#
# See README.md section 4 ("State checkpoints") for what each file means and how
# to read the diff. Companion: diff-snapshots.sh.

set -uo pipefail

LABEL="${1:-}"
case "$LABEL" in
  before|after) ;;
  *) echo "usage: $(basename "$0") <before|after> [output-root]" >&2; exit 2 ;;
esac

ROOT="${2:-snapshots}"
CTX="$(kubectl config current-context 2>/dev/null)" || {
  echo "error: no active kube-context" >&2; exit 1
}
OUT="${ROOT}/${CTX}/${LABEL}"
mkdir -p "$OUT"

echo "Snapshotting context '${CTX}' (${LABEL}) -> ${OUT}"

has_crd() { kubectl get crd "$1" >/dev/null 2>&1; }

# Collapse repeated images within a single "<id>\t<img> <img> ..." line, keeping
# first-seen order. Multi-container/initContainer workloads often share one image.
dedupe_line_images() {
  awk -F'\t' '{
    split("", seen); out=""
    n = split($2, a, " ")
    for (i = 1; i <= n; i++)
      if (a[i] != "" && !(a[i] in seen)) { seen[a[i]] = 1; out = (out == "" ? a[i] : out " " a[i]) }
    print $1 "\t" out
  }'
}

# --- Dimension 1: Tanzu repositories, packages, versions, reconcile status ---
tanzu package repository list -A > "$OUT/repositories.txt"       2>/dev/null || true
tanzu package installed list  -A > "$OUT/packages-installed.txt" 2>/dev/null || true
kubectl get pkgr -A -o wide      > "$OUT/pkgr.txt"               2>/dev/null || true
kubectl get pkgi -A -o wide      > "$OUT/pkgi.txt"               2>/dev/null || true
# What each PackageInstall pins (a wide constraint uptakes the new catalog max)
kubectl get pkgi -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.packageRef.refName} @ {.spec.packageRef.versionSelection.constraints}{"\n"}{end}' 2>/dev/null \
  | sort > "$OUT/pkgi-constraints.txt" || true
# Reconcile status, not just version (a pkgi can show the new version yet fail)
kubectl get pkgi -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DESC:.status.friendlyDescription' \
  > "$OUT/pkgi-status.txt" 2>/dev/null || true

# --- Dimension 2: Node states ---
kubectl get nodes -o wide > "$OUT/nodes.txt" 2>/dev/null || true

# --- Dimension 3: Workloads + their images ---
kubectl get deploy,daemonset,statefulset,cronjob,job,pods -A -o wide \
  > "$OUT/workloads.txt" 2>/dev/null || true
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>/dev/null \
  | dedupe_line_images | sort > "$OUT/pod-images.txt" || true

# --- #1: CRD served & storage versions (the Flux mechanism, generalized) ---
kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name}: served=[{range .spec.versions[*]}{.name}({.served}) {end}] storage={.spec.versions[?(@.storage)].name}{"\n"}{end}' 2>/dev/null \
  | sort > "$OUT/crd-versions.txt" || true

# --- #2: API surface / discovery health (the literal symptom of the CD break) ---
kubectl get apiservices -o wide > "$OUT/apiservices.txt" 2>/dev/null || true
# stderr here catches "unable to retrieve the complete list of server APIs: <group>"
kubectl api-resources > "$OUT/api-resources.txt" 2> "$OUT/api-resources.err" || true

# --- #3: Flux CR reconcile truth (where CD-enabled) ---
# Query each kind separately: `kubectl get a,b,c` fails the WHOLE command if any
# one kind's CRD is absent (e.g. no helmreleases when helm-controller isn't
# installed — TMC CD ships only source + kustomize controllers), which would
# silently blank the file even when other Flux CRs exist.
: > "$OUT/flux-resources.txt"
FLUX_KINDS="$(kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}')"
for kind in gitrepositories kustomizations helmreleases helmrepositories ocirepositories buckets; do
  printf '%s\n' "$FLUX_KINDS" | grep -qx "$kind" || continue
  echo "=== $kind ===" >> "$OUT/flux-resources.txt"
  kubectl get "$kind" -A -o wide >> "$OUT/flux-resources.txt" 2>/dev/null || true
  echo >> "$OUT/flux-resources.txt"
done

# --- #4: Admission webhooks (cert-manager et al. can silently rewrite these) ---
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o wide \
  > "$OUT/webhooks.txt" 2>/dev/null || true

# --- #5: Guest component health, where installed (Contour / cert-manager) ---
if has_crd httpproxies.projectcontour.io; then
  kubectl get httpproxy -A > "$OUT/contour-httpproxy.txt" 2>/dev/null || true
fi
if has_crd certificates.cert-manager.io || has_crd clusterissuers.cert-manager.io; then
  # Query each kind separately and guard each on its own CRD: a combined
  # `get certificate,clusterissuer` fails whole if either type is absent (same
  # footgun as the Flux CR query). ClusterIssuer is cluster-scoped, so it is
  # listed without -A.
  : > "$OUT/cert-manager.txt"
  if has_crd certificates.cert-manager.io; then
    echo "=== certificates ===" >> "$OUT/cert-manager.txt"
    kubectl get certificate -A >> "$OUT/cert-manager.txt" 2>/dev/null || true
    echo >> "$OUT/cert-manager.txt"
  fi
  if has_crd clusterissuers.cert-manager.io; then
    echo "=== clusterissuers ===" >> "$OUT/cert-manager.txt"
    kubectl get clusterissuer >> "$OUT/cert-manager.txt" 2>/dev/null || true
    echo >> "$OUT/cert-manager.txt"
  fi
fi

# --- Named component version matrix: cert-manager, contour, fluxcd, velero ---
# Explicit callout of the four components whose version deltas matter most,
# pinned two ways: the resolved PackageInstall version (where it is a package)
# and the actual runtime container image TAG (authoritative, and the only signal
# for velero, which TMC Data Protection deploys outside the Standard repo).
COMPONENT_RE='cert-manager|contour|envoy|source-controller|kustomize-controller|helm-controller|fluxcd|flux|velero|node-agent'
{
  echo "# Component version matrix — context ${CTX} (${LABEL})"
  echo
  echo "## PackageInstall resolved versions (cert-manager / contour / fluxcd)"
  kubectl get pkgi -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PACKAGE:.spec.packageRef.refName,VERSION:.status.version' 2>/dev/null \
    | grep -Ei "PACKAGE|cert-manager|contour|flux" || echo "(none found)"
  echo
  echo "## Runtime container image tags (initContainers + containers)"
  # Query each workload kind separately so an absent type can't blank the whole
  # capture (same footgun as the Flux CR query above). deploy/ds/sts are core
  # built-ins so they're always present today, but this keeps the pattern uniform
  # and future-proofs adding any CRD-backed workload kind to the list.
  for wl in deployment daemonset statefulset; do
    kubectl get "$wl" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.kind}/{.metadata.name}{"\t"}{range .spec.template.spec.initContainers[*]}{.image}{" "}{end}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>/dev/null
  done | dedupe_line_images | grep -Ei "$COMPONENT_RE" | sort -u || echo "(none found)"
} > "$OUT/component-versions.txt" 2>/dev/null || true
# velero CLI version too, if the client is installed and can reach the cluster
if command -v velero >/dev/null 2>&1; then
  { echo; echo "## velero version"; velero version 2>/dev/null; } >> "$OUT/component-versions.txt" || true
fi

# Flag anything discovery couldn't enumerate — loudest signal of the §7 break
if [ -s "$OUT/api-resources.err" ]; then
  echo "  ! discovery errors captured in ${OUT}/api-resources.err:"
  sed 's/^/    /' "$OUT/api-resources.err"
fi

echo "wrote ${OUT}"

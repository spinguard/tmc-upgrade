#!/usr/bin/env bash
#
# setup-namespace.sh [supervisor-vip]
#
# Creates and verifies the vSphere Namespace on the Supervisor that
# tmc-cluster.yaml provisions into. A vSphere Namespace is a Supervisor
# (Workload Management) object — there is no option for it in the normal
# vCenter inventory UI, so this script is the CLI equivalent of the
# Workload Management > Namespaces > New Namespace wizard.
#
# It will:
#   1. (optional) log in to the Supervisor if not already authenticated
#   2. create the namespace if it is missing
#   3. verify the storage class, VM class, and TKR that the manifest
#      references are actually available to the namespace
#
# IMPORTANT: creating the bare namespace is NOT enough. Storage policy, VM
# classes, content library, and user permissions are bound to the namespace
# from the vCenter side (Workload Management UI, or vSphere admin APIs) and
# CANNOT be reliably wired up with kubectl. If step 3 reports anything
# missing, finish the wiring in the vSphere Client before applying the
# manifest, otherwise `kubectl apply -f tmc-cluster.yaml` will succeed but
# the Cluster will never provision.
#
# Values below are derived from tmc-cluster.yaml — keep them in sync if the
# manifest changes.
#
# Usage:
#   resources/setup-namespace.sh                       # namespace already logged in
#   resources/setup-namespace.sh 192.168.204.1         # log in first, then set up
#   SUPERVISOR_USER=administrator@vsphere.local \
#     resources/setup-namespace.sh 192.168.204.1

set -uo pipefail

MANIFEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${MANIFEST_DIR}/tmc-cluster.yaml"

# --- values that must match tmc-cluster.yaml -------------------------------
NAMESPACE="tmc-sm"                 # metadata.namespace
# The manifest splits storage: control-plane containerd data volume uses the
# management policy; node boot disks, worker data volumes, and the guest
# default StorageClass use the vSAN policy. Both must be bound to tmc-sm.
STORAGE_CLASSES=(
  "management-storage-policy-regular"   # control-plane containerd volume
  "vsan-default-storage-policy"         # storageClass / worker volume / defaultStorageClass
)
VM_CLASS="best-effort-large"       # vmClass overrides
TKR="v1.33.6"                      # topology.version (v1.33.6+vmware.1-fips)

SUPERVISOR_VIP="${1:-}"
SUPERVISOR_USER="${SUPERVISOR_USER:-administrator@vsphere.local}"

ok()    { printf '  [ ok ]  %s\n' "$*"; }
warn()  { printf '  [WARN]  %s\n' "$*" >&2; }

# --- 1. login (optional) ----------------------------------------------------
if [ -n "$SUPERVISOR_VIP" ]; then
  echo "Logging in to Supervisor ${SUPERVISOR_VIP} as ${SUPERVISOR_USER} ..."
  if ! kubectl vsphere login \
        --server="$SUPERVISOR_VIP" \
        --vsphere-username "$SUPERVISOR_USER" \
        --insecure-skip-tls-verify; then
    echo "login failed" >&2
    exit 1
  fi
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "No reachable cluster in the current kube-context." >&2
  echo "Pass the Supervisor VIP to log in, e.g.:  $(basename "$0") <supervisor-vip>" >&2
  exit 1
fi

# --- 2. create the namespace ------------------------------------------------
echo "Namespace '${NAMESPACE}':"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ok "already exists"
else
  if kubectl create namespace "$NAMESPACE"; then
    ok "created"
  else
    warn "could not create namespace '${NAMESPACE}'"
    exit 1
  fi
fi

# --- 3. verify prerequisites the manifest needs -----------------------------
missing=0

# A storage policy existing cluster-wide is NOT the same as it being assigned to
# the namespace. A policy bound to the namespace shows up as a storage-scoped
# entry in the namespace's resourcequota; that binding is what the manifest needs.
echo "Storage policies bound to '${NAMESPACE}':"
quota="$(kubectl get resourcequota -n "$NAMESPACE" -o jsonpath='{.items[*].status.hard}' 2>/dev/null)"
for sc in "${STORAGE_CLASSES[@]}"; do
  if printf '%s' "$quota" | grep -q "${sc}.storageclass.storage.k8s.io/requests.storage"; then
    ok "'${sc}' bound"
  elif kubectl get storageclass "$sc" >/dev/null 2>&1; then
    warn "'${sc}' exists but is NOT bound to '${NAMESPACE}' — add it in Workload Management > Storage"
    missing=1
  else
    warn "'${sc}' not found on the Supervisor — check the policy name / vCenter storage policy"
    missing=1
  fi
done

# VirtualMachineClass is namespaced in the Supervisor: a class shows up under
# the namespace only once it is bound to it, so this must be queried with -n.
echo "VM class '${VM_CLASS}' bound to '${NAMESPACE}':"
if err="$(kubectl get virtualmachineclass "$VM_CLASS" -n "$NAMESPACE" 2>&1 >/dev/null)"; then
  ok "bound"
elif printf '%s' "$err" | grep -qiE "not found|no resources|doesn't have"; then
  warn "not bound — add it under Workload Management > VM Service > VM Classes for '${NAMESPACE}'"
  missing=1
else
  warn "could not verify (API error: ${err}) — re-run when the Supervisor is stable"
  missing=1
fi

# Distinguish "TKR absent" from a transient API error — don't warn on the latter.
echo "TKR matching '${TKR}':"
if tkrs="$(kubectl get tanzukubernetesreleases 2>&1)"; then
  if printf '%s' "$tkrs" | grep -q "$TKR"; then
    ok "available"
  else
    warn "no TKR matching '${TKR}' — attach the TKR content library to '${NAMESPACE}'"
    missing=1
  fi
else
  warn "could not list TKRs (API error) — re-run when the Supervisor is stable"
  missing=1
fi

echo
if [ "$missing" -ne 0 ]; then
  echo "Namespace exists, but one or more prerequisites are missing (see [WARN] above)."
  echo "Finish the wiring in the vSphere Client, then apply the manifest:"
else
  echo "Namespace '${NAMESPACE}' is ready. Apply the cluster manifest:"
fi
echo "    kubectl apply -f ${MANIFEST}"

exit "$missing"

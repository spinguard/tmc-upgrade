#!/usr/bin/env bash
#
# nsx-vip-diag.sh — Diagnostic dump for the TMC ingress / control-plane VIP collision.
#
# Purpose: hand this output to the NSX / vCenter / VKS admin. It shows (1) the failing
# TMC contour-envoy LoadBalancer and the VIP it needs, and (2) the Supervisor's view of
# the NSX-native LB pool and current VIP allocations.
#
# THE ISSUE (one line): the TMC ingress must bind a STATIC VIP (default .196, fixed by
# DNS + cert SANs, cannot move), but that same address was handed out DYNAMICALLY from
# the shared NSX LB pool to the tmc guest cluster's control-plane VIP — so the ingress
# LoadBalancer is stuck. We need .196 reserved for the static ingress and kept out of the
# dynamic allocation range (ideally: separate control-plane VIPs from Service-LB VIPs).
#
# Read-only: this script only runs `kubectl get/describe`. It changes nothing.
#
# Usage:
#   ./nsx-vip-diag.sh                 # uses defaults below
#   GUEST_CTX=tmc SUP_CTX=tmc-sm ./nsx-vip-diag.sh
#   ./nsx-vip-diag.sh > tmc-vip-diag.txt   # capture to a file to send
#
set -uo pipefail

# ---- Configurable via environment ------------------------------------------------------
GUEST_CTX="${GUEST_CTX:-tmc}"                 # kube context for the TMC guest cluster
SUP_CTX="${SUP_CTX:-tmc-sm}"                  # kube context for the Supervisor
GUEST_NS="${GUEST_NS:-tmc-local}"             # namespace where TMC runs in the guest
SUP_NS="${SUP_NS:-tmc-sm}"                    # Supervisor namespace for the tmc cluster
SVC="${SVC:-contour-envoy}"                   # the TMC ingress LoadBalancer service
POOL="${POOL:-192.168.204.192/27}"            # NSX external_ip_pools_lb (informational)
# ---------------------------------------------------------------------------------------

line() { printf '=%.0s' {1..88}; echo; }
hdr()  { echo; line; echo "## $*"; line; }
# run: echo the command (for transparency), then execute it.
run()  { printf '$ %s\n\n' "$*"; eval "$*"; }

echo "TMC ingress / control-plane VIP collision — diagnostic dump"
echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')   host: $(hostname)"
echo "guest-ctx=${GUEST_CTX}  supervisor-ctx=${SUP_CTX}  lb-pool=${POOL}"

hdr "1. FAILING TMC INGRESS — describe ${GUEST_NS}/${SVC} (guest cluster)"
echo "# 'Desired LoadBalancer IP' = the static VIP TMC needs; the Events show the failure."
echo
run "kubectl --context ${GUEST_CTX} -n ${GUEST_NS} describe service ${SVC} 2>&1"

hdr "2. LB PROVIDER — confirm NSX-native (NCP), not Avi"
echo "# nsx-ncp pods (networking + native L4 LB):"
echo
run "kubectl --context ${SUP_CTX} -n vmware-system-nsx get pods 2>&1"
echo
echo "# AKO/Avi operator (expected present-but-dormant: avi-k8s-config has 0 data):"
echo
run "kubectl --context ${SUP_CTX} -n vmware-system-ako get cm 2>&1"

hdr "3. NSX LB POOL DEFINITION — from nsx-ncp-config (ncp.ini)"
echo "# external_ip_pools_lb is the LoadBalancer VIP pool. nsx_api_managers = NSX Manager."
echo
run "kubectl --context ${SUP_CTX} -n vmware-system-nsx get cm nsx-ncp-config -o jsonpath='{.data.ncp\.ini}' 2>&1 | tr -d '\r' | grep -iE '^[[:space:]]*(external_ip_pools|external_ip_pools_lb|use_native_loadbalancer|use_avi_lb|nsx_api_managers|tier0_gateway|edge_cluster|container_ip_blocks|subnet_prefix)[[:space:]]*=' | sed 's/^[[:space:]]*//'"

hdr "4a. LoadBalancer SERVICES (Supervisor view, all namespaces)"
run "kubectl --context ${SUP_CTX} get svc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,REQUESTED:.spec.loadBalancerIP,ASSIGNED-VIP:.status.loadBalancer.ingress[0].ip' 2>&1 | awk 'NR==1 || /LoadBalancer/'"

hdr "4b. VirtualMachineServices (Supervisor view, all namespaces)"
run "kubectl --context ${SUP_CTX} get virtualmachineservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,REQUESTED:.spec.loadBalancerIP,ASSIGNED-VIP:.status.loadBalancer.ingress[0].ip' 2>&1"

hdr "5. VIP ALLOCATION MAP + free candidates in ${POOL}"
if command -v python3 >/dev/null 2>&1; then
  echo "# data source (parsed by python3 against ${POOL}):"
  printf '$ %s\n'   "kubectl --context ${SUP_CTX} get svc -A -o json"
  printf '$ %s\n\n' "kubectl --context ${SUP_CTX} get virtualmachineservice -A -o json"
  svc_json="$(kubectl --context "${SUP_CTX}" get svc -A -o json 2>/dev/null)"
  vms_json="$(kubectl --context "${SUP_CTX}" get virtualmachineservice -A -o json 2>/dev/null)"
  POOL="${POOL}" python3 - "$svc_json" "$vms_json" <<'PY'
import os, sys, json, ipaddress
pool = ipaddress.ip_network(os.environ["POOL"])
def rows(kind, raw):
    out=[]
    if not raw: return out
    for it in json.loads(raw).get("items", []):
        sp=it.get("spec",{})
        if kind=="svc" and sp.get("type")!="LoadBalancer": continue
        ns=it["metadata"]["namespace"]; name=it["metadata"]["name"]
        req=sp.get("loadBalancerIP","") or ""
        ing=[g.get("ip","") for g in it.get("status",{}).get("loadBalancer",{}).get("ingress",[]) if g.get("ip")]
        out.append((ing, req, kind, ns, name))
    return out
data = rows("svc", sys.argv[1]) + rows("vmsvc", sys.argv[2])
alloc={}; pending=[]
for ing, req, kind, ns, name in data:
    if ing:
        for v in ing: alloc.setdefault(v, []).append(f"{kind} {ns}/{name}")
    else:
        pending.append((req, kind, ns, name))
print("ALLOCATED (as seen by this Supervisor):")
for v in sorted(alloc, key=lambda x: ipaddress.ip_address(x)):
    tag = "" if ipaddress.ip_address(v) in pool else "  (OUTSIDE pool)"
    print(f"  {v:16} {'; '.join(alloc[v])}{tag}")
print("\nPENDING (requested but no VIP assigned — the stuck ones):")
for req, kind, ns, name in pending:
    print(f"  requested={req or '-':16} {kind} {ns}/{name}")
taken=set(alloc)
free=[str(ip) for ip in pool.hosts() if str(ip) not in taken]
print(f"\nFREE in {pool} per THIS Supervisor ({len(free)}): {', '.join(free)}")
print("  NOTE: this is the Supervisor's view only. VIPs held by OTHER clusters")
print("  (e.g. test1/test2 endpoints) are NOT visible here — NSX Manager is authoritative.")
PY
else
  echo "(python3 not found — see sections 4a/4b for raw allocations)"
fi

hdr "6. WHAT WE'RE ASKING THE NSX ADMIN"
cat <<EOF
* Reserve the TMC ingress VIP (see 'Desired LoadBalancer IP' in section 1) as a STATIC
  VIP, excluded from the DYNAMIC allocation range of the NSX LB pool (${POOL}), so a
  reprovisioned guest cluster's control-plane VIP can never claim it.
* Ideally separate guest-cluster CONTROL-PLANE VIPs from Service-LoadBalancer VIPs into
  non-overlapping ranges, so this class of collision can't recur.
* Please confirm the pool's authoritative occupancy from NSX Manager, and advise whether
  the LB pool / allocation range was changed recently.
* Note: the ingress VIP is currently HELD by the tmc control-plane VMService. Freeing it
  will require either an NSX-side reassignment or one more guest-cluster reprovision after
  the reservation is in place.
EOF
echo
line
echo "END OF REPORT"

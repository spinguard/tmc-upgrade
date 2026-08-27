# TMC Self-Managed 1.4.5 — managed cluster upgrade to Kubernetes 1.36 never offered

**Summary:** TMC reports `NoUpgradeVersions` for a VKS guest cluster whose target release is
present, `READY`, `COMPATIBLE`, explicitly supported by the 1.4.5 release notes, **and present in
the Supervisor-side option set TMC consumes**. The same deployment performed a larger
cross-ClusterClass upgrade of this same cluster under TMC SM 1.4.4, which makes this a
regression.

| Field | Value |
|---|---|
| TMC Self-Managed | 1.4.5 |
| vSphere Supervisor | v1.32.7+vmware.5-fips |
| VKS | 3.7 (upgraded from 3.6.3) |
| Affected cluster | `dev1` |
| Current → target | v1.35.6+vmware.2 → v1.36.2+vmware.2 |
| Observed | 2026-08-27 UTC |

---

## Impact

Guest-cluster upgrades cannot be driven through TMC. This deployment's operating model relies on
TMC for provisioning, deprovisioning, and upgrade of all guest clusters, so an out-of-band
Supervisor edit is not an acceptable workaround — it bypasses the very control plane being
validated.

After upgrading VKS from 3.6.3 to 3.7 (which delivers VKr v1.36 and ClusterClass
`builtin-generic-v3.7.0`), the TMC console offers no upgrade for the managed cluster `dev1`, and
`tanzu mission-control cluster get` reports the cluster is already at the latest version. The
Supervisor advertises v1.36 correctly.

The same VKS-upgrade-then-cluster-upgrade sequence worked through TMC on this deployment
previously (VKS 3.4.1 → 3.6.3 under TMC SM 1.4.4), including automatic ClusterClass rebase.

---

## Environment

| Component | Version | Note |
|---|---|---|
| TMC Self-Managed | 1.4.5 | `package-repository:1.4.5`, all PackageInstalls reconciled |
| vSphere Supervisor | v1.32.7+vmware.5-fips | 3 control-plane nodes |
| ESXi | v1.32.5-sph-cd37574 | 4 hosts |
| VKS | 3.7 | upgraded from 3.6.3 on 2026-08-26 23:42 UTC |
| TMC Supervisor Service ns | `svc-tmc-c9` | all 8 deployments 1/1 READY |
| Affected cluster | `dev1` | ns `tmc-sm`, mgmt cluster `non-prod-mgr`, provisioner `tmc-sm` |
| dev1 current | v1.35.6+vmware.2 | class `vmware-system-vks-public/builtin-generic-v3.6.0` |
| Intended target | v1.36.2+vmware.2 | vkr `v1.36.2---vmware.2-vkr.3` |

A second cluster in the same namespace, `tmc` (which hosts TMC SM itself and is therefore not
TMC-managed), was moved to `builtin-generic-v3.7.0` / `v1.36.2+vmware.2` by editing
`spec.topology.version` directly. That upgrade succeeded and the ClusterClass rebased
automatically — confirming the Supervisor, the vKr, and the ClusterClass are all functional.

---

## Evidence

### E1 — Supervisor advertises v1.36 as ready and compatible

```
$ kubectl get kr
NAME                        VERSION                    READY   COMPATIBLE   CREATED
v1.35.6---vmware.2-vkr.3    v1.35.6+vmware.2-vkr.3     True    True          9d
v1.36.1---vmware.4-vkr.5    v1.36.1+vmware.4-vkr.5     True    True         28d
v1.36.2---vmware.2-vkr.3    v1.36.2+vmware.2-vkr.3     True    True          9d
```

ClusterClass `builtin-generic-v3.7.0` is present in `vmware-system-vks-public` (created
`2026-08-26T23:42:23Z`) and advertises `min-version-supported=v1.33`,
`max-version-supported=v1.36`.

### E2 — TMC computes an empty upgrade-candidate list

```
$ tanzu mission-control cluster get dev1 -m non-prod-mgr -p tmc-sm
    version: v1.35.6+vmware.2-vkr.3
    VersionIsLatest:
      type: VersionIsLatest
      reason: NoUpgradeVersions
    ClassRebaseNeeded:
      type: ClassRebaseNeeded
      status: FALSE
      severity: INFO
      reason: NoUpgradeVersions
    Managed:            status: TRUE
    KubernetesProvider: type=VMWARE_TANZU_KUBERNETES_GRID_SERVICE
  phase: READY
```

Both conditions bottom out in `NoUpgradeVersions`. TMC is not rejecting v1.36 on compatibility
grounds — it never received v1.36 as a candidate. `ClassRebaseNeeded` being `FALSE` is a
downstream consequence of the empty list, not an independent block.

### E3 — The retriever does see v1.36, so data reaches the Supervisor agent

```
$ kubectl -n svc-tmc-c9 logs deploy/vsphere-resource-retriever --since=15m \
    | grep -ioE "kubernetesrelease|v1\.3[456]" | sort | uniq -c
    318 KubernetesRelease
     36 v1.34
     42 v1.35
     20 v1.36
```

The failure is therefore not blindness to the release. Combined with E7, the render is also
correct — leaving publication or consumption as the failing step.

### E4 — `vsphereoptions/options` is rewritten continuously

`renderer-controller` declares its config changed and rewrites the object several times per
second, losing writes to optimistic-concurrency conflicts. `sync-agent` forwards every one of
those modifications to TMC.

| Signal | Measured | Expected at steady state |
|---|---|---|
| `VsphereOption` MODIFIED events sent to TMC | 170–173 / min | ~0 |
| All other synced kinds combined (`Node`) | 46–48 / min | low |
| Retriever log volume | 1,497–1,504 / min | low |
| Lost writes on `options` | 33–187 / 15 min | 0 |
| Retriever pod restarts | 0 (uptime 3h4m) | 0 |

```
renderer-controller, repeating ~3x/second:

msg:"Starting reconcile"  namespaced_name:{Namespace:"svc-tmc-c9", Name:"options"}
msg:"Resources have changed; updating the config"
error:"unable to update Option svc-tmc-c9/options: Operation cannot be fulfilled on
       vsphereoptions.run.tanzu.vmware.com \"options\": the object has been modified;
       please apply your changes to the latest version and try again"
msg:"Reconciler error"

sync-agent, same window (x170/min):

{"component":"sync-agent","eventType":"MODIFIED","kind":"VsphereOption","name":"options",
 "namespace":"svc-tmc-c9","msg":"sent event","time":"2026-08-27T02:41:38Z"}
```

### E5 — The inputs are not changing; the render is nondeterministic

Sampling the renderer's inputs 11 seconds apart returns byte-identical `resourceVersion`s.
Nothing upstream is flapping, yet the output is rewritten ~30 times across that same interval.

```
21:44:43 → 21:44:54, storagepolicyquota + namespace resourceVersions

svc-tkg-domain-c9     nfs-pool-1-policy-storagepolicyquota    11029  →  11029
svc-velero-domain-c9  nfs-pool-1-policy-storagepolicyquota    11068  →  11068
tmc-sm                nfs-pool-1-policy-storagepolicyquota 34516299  →  34516299
tmc-sm                vsan-default-storage-policy-...         37274  →  37274
ns/svc-tkg-domain-c9                                       34552816  →  34552816
ns/svc-velero-domain-c9                                    34554211  →  34554211
ns/tmc-sm                                                     14805  →  14805

unchanged inputs, ~30 rewrites of options in the same window
```

Each render pass re-enumerates the same eight storage classes across four namespaces. If that
collection is assembled in nondeterministic order, every pass would differ from the last and the
controller would never converge.

### E6 — Possible trigger: duplicate ClusterClass names across namespaces

Three ClusterClass names exist in two namespaces simultaneously. No cluster references the
`tmc-sm` copies.

```
tmc-sm                     builtin-generic-v3.1.0   2026-07-29T23:52:48Z
tmc-sm                     builtin-generic-v3.2.0   2026-07-29T23:52:48Z
tmc-sm                     builtin-generic-v3.3.0   2026-07-29T23:52:49Z
vmware-system-vks-public   builtin-generic-v3.1.0   2026-07-29T23:56:52Z   <- duplicate name
vmware-system-vks-public   builtin-generic-v3.2.0   2026-07-29T23:56:52Z   <- duplicate name
vmware-system-vks-public   builtin-generic-v3.3.0   2026-07-29T23:56:50Z   <- duplicate name
vmware-system-vks-public   builtin-generic-v3.4.0 ... v3.7.0

in use:  dev1 -> vmware-system-vks-public/builtin-generic-v3.6.0
         tmc  -> vmware-system-vks-public/builtin-generic-v3.7.0
```

Offered as a candidate for name-keyed collation producing unstable output. Note the duplicates
have existed since 2026-07-29 and TMC-brokered upgrades succeeded after that date, so this is
unlikely to be a sufficient cause on its own.

### E7 — The published option set DOES contain v1.36

Read directly from the Supervisor control plane with `/etc/kubernetes/admin.conf`:

```
$ kubectl -n svc-tmc-c9 get vsphereoptions options -o yaml | grep 1.36
   <v1.36 releases present>
```

This is the single most important finding. The Supervisor-side render is **correct** — v1.36 is
computed and persisted into the object TMC consumes. The defect is therefore **downstream of the
render**, in publication or consumption, not in resource discovery.

It also means the rewrite loop (E4/E5) may be a **secondary** defect rather than the direct cause,
though a consumer receiving 170 modifications per minute of the same object is a plausible
mechanism for never settling on a version set.

### E8 — Regression: the same cluster made a LARGER cross-class jump under 1.4.4

ClusterClass version windows on this Supervisor:

| ClusterClass | min | max |
|---|---|---|
| builtin-generic-v3.4.0 | v1.29 | **v1.33** |
| builtin-generic-v3.5.0 | v1.31 | v1.34 |
| builtin-generic-v3.6.0 | v1.32 | **v1.35** |
| builtin-generic-v3.7.0 | v1.33 | **v1.36** |

Under **TMC SM 1.4.4**, after a VKS 3.4.1 → 3.6.3 upgrade, TMC offered and successfully brokered
an upgrade of `dev1` from vKr 1.33 on ClusterClass `builtin-generic-v3.4.0` (ceiling v1.33) to
**v1.35.6 on `builtin-generic-v3.6.0`** — crossing three ClusterClass generations and two version
ceilings, with automatic rebase.

TMC's own stored intent still records the origin: `dev1`'s
`run.tanzu.vmware.com/last-applied-configuration` contains
`"topology":{"version":"v1.33.6+vmware.1-fips-vkr.2"}` while the live cluster runs
`v1.35.6+vmware.2`.

Under **TMC SM 1.4.5**, the same cluster in the same deployment will not be offered a
**single**-generation jump (3.6.0 → 3.7.0, v1.35.6 → v1.36.2).

### E9 — Management cluster is healthy and current

```
$ tanzu mission-control management-cluster get non-prod-mgr
  phase: READY          health: HEALTHY
  ExtensionsOutOfSync:  status FALSE   reason: ExtensionsUpToDate
  READY:                status TRUE    "management cluster is connected to TMC and healthy"
  extensions: [vsphere-resource-retriever, agent-updater, cluster-health-extension,
               extension-manager, extension-updater, intent-agent, sync-agent, tmc-auto-attach]
  lastUpdate: 2026-08-27T03:33:11Z
  kubeServerVersion: v1.32.7+vmware.5-fips
```

No connectivity, staleness, or extension-version explanation is available.

### E10 — Restarting the retriever does NOT clear the loop (cold-start reproducible)

`vsphere-resource-retriever` was restarted from the Supervisor control plane using
`/etc/kubernetes/admin.conf`. A new pod came up clean (new ReplicaSet hash, 0 restarts). The
rewrite loop resumed at full rate within minutes:

| Signal | Pre-restart | Post-restart (T+6m) |
|---|---|---|
| Lost writes on `options` / 15 min | 33–187 | 64 |
| Retriever log lines / 60s | ~1,500 | 1,555 |
| `VsphereOption` events to TMC / 60s | 170 | 173 |
| `Node` events / 60s | 46 | 49 |

The behaviour is therefore **reproducible from a cold start**, not accumulated or corrupted
in-memory state. `dev1` remains blocked:

```
$ tanzu mission-control cluster get dev1 -m non-prod-mgr -p tmc-sm
--- VersionIsLatest
      status: TRUE
      lastTransitionTime: 2026-08-27T03:46:04.824641920Z    <- recomputed seconds before query
--- ClassRebaseNeeded
      status: FALSE
      reason: NoUpgradeVersions
--- Managed:  status TRUE
--- Ready:    status TRUE
spec.topology.version: v1.35.6+vmware.2-vkr.3
```

TMC is actively recomputing the condition and still concluding no upgrade exists, while v1.36 is
present in `vsphereoptions/options` (E7).

---

## Ruled out

- **Unsupported target version.** The 1.4.5 release notes state support for provisioning and
  attaching v1.36 clusters, and add lifecycle management for VKS 3.7 including VKr v1.36 and
  `builtin-generic-v3.7.0`. The interoperability matrix agrees.
- **Missing or unhealthy vKr.** Both v1.36.1 and v1.36.2 are `READY=True`, `COMPATIBLE=True` on
  the Supervisor (E1).
- **ClusterClass ceiling blocking the hop.** Disproven by this deployment's own history (E8):
  TMC previously moved `dev1` from class `builtin-generic-v3.4.0` (ceiling v1.33) to
  `builtin-generic-v3.6.0` at v1.35.6 — three class generations, two ceilings crossed, rebased
  automatically. TMC demonstrably computes candidates across class boundaries and exposes a
  dedicated `ClassRebaseNeeded` condition for exactly this. `builtin-generic-v3.7.0` is present
  and supports v1.36.
- **Resource discovery on the Supervisor.** Disproven by E7: v1.36 is present in the published
  `vsphereoptions/options` object.
- **Management cluster connectivity or stale extensions.** Disproven by E9.
- **The 1.4.5 cluster-autoscaler known issue.** `dev1` does carry
  `addon.addons.kubernetes.vmware.com/cluster-autoscaler: automatic`, but `intent-agent` logs
  contain zero autoscaler references over 30 minutes, and no autoscaler reconciliation conflicts
  appear anywhere.
- **Cluster not actually managed.** `dev1` is `phase: Provisioned`, `Managed: TRUE`, and appears
  in `tanzu mission-control cluster list` under management cluster `non-prod-mgr`.
- **Agent unhealthy or crash-looping.** All eight `svc-tmc-c9` deployments are 1/1; the retriever
  has 0 restarts across 3h+ uptime.

---

## Reproduction

1. vSphere Supervisor with TMC Self-Managed 1.4.5 and a TMC-managed VKS guest cluster at v1.35.x
   on ClusterClass `builtin-generic-v3.6.0`.
2. Upgrade VKS 3.6.3 → 3.7, delivering VKr v1.36.x and `builtin-generic-v3.7.0`.
3. Confirm the Supervisor lists v1.36 as `READY` / `COMPATIBLE` (E1).
4. Open the managed cluster in the TMC console — no upgrade option is presented.
5. Run `tanzu mission-control cluster get <cluster> -m <mgmt> -p <provisioner>` — observe
   `VersionIsLatest` / `NoUpgradeVersions` (E2).
6. Inspect `svc-tmc-c9` for the rewrite loop (E4) and confirm inputs are static (E5).

---

## What we need

1. **Why does TMC compute `NoUpgradeVersions` when v1.36 is present in
   `vsphereoptions/options` (E7)?** Where between that object and the cluster's
   `VersionIsLatest` condition is the candidate list filtered to empty?
2. **Is this a known regression between 1.4.4 and 1.4.5?** E8 documents the same cluster in the
   same deployment completing a strictly larger cross-ClusterClass upgrade under 1.4.4.
3. **Is the `vsphereoptions/options` rewrite rate expected?** At ~170 modifications per minute
   with static inputs we believe it is not (E4/E5). Is a consumer receiving that rate able to
   settle on a version set, or is this the mechanism of the failure?
4. **Are duplicate ClusterClass names across namespaces (E6) a known trigger**, and is it safe to
   remove the unreferenced `tmc-sm` copies?
5. **Is there a supported way to force TMC to re-sync** a management cluster's available
   Kubernetes versions, short of restarting Supervisor Service workloads?

---

## Diagnostic access limitations

Two checks could not be completed. Both are denied to `sso:Administrator@vsphere.local` against
the Supervisor, because `svc-tmc-c9` is a Supervisor Service namespace:

```
$ kubectl -n svc-tmc-c9 get vsphereoptions options -o yaml
Error from server (Forbidden): vsphereoptions.run.tanzu.vmware.com is forbidden:
User "sso:Administrator@vsphere.local" cannot list resource "vsphereoptions"
in API group "run.tanzu.vmware.com" in the namespace "svc-tmc-c9"

$ kubectl -n svc-tmc-c9 auth can-i patch deployments
no
$ kubectl -n svc-tmc-c9 auth can-i delete pods
no
```

Both gaps have since been closed using the Supervisor control-plane node's
`/etc/kubernetes/admin.conf`: the option set was read (E7, v1.36 present) and the retriever was
restarted (E10, loop reproduces from cold start). The RBAC note is retained because it affects
what a customer can self-diagnose without control-plane node access.

---

*Case prepared 2026-08-27 · lab1 · TMC Self-Managed 1.4.5 · vSphere Supervisor
v1.32.7+vmware.5-fips. All measurements taken from a running system with no restarts or
configuration changes applied during collection.*

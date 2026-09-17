# TMC Self-Managed 1.4.5 — managed cluster upgrade never offered past its current ClusterClass ceiling

**Summary:** TMC reports `NoUpgradeVersions` for a VKS guest cluster whose target release is
present, `READY`, `COMPATIBLE`, explicitly supported by the 1.4.5 release notes, and **present in
the Supervisor-side option set TMC consumes**. The evidence indicates TMC clamps its
upgrade-candidate list to the `max-version-supported` ceiling of the cluster's *current*
ClusterClass, and evaluates `ClassRebaseNeeded` from that already-empty list. The rebase that
would raise the ceiling is therefore gated behind a candidate list the ceiling has emptied.

| Field | Value |
|---|---|
| TMC Self-Managed | 1.4.5 |
| vSphere Supervisor | v1.32.7+vmware.5-fips |
| VKS | 3.7 (upgraded from 3.6.3) |
| Affected cluster | `dev1` (blocked); `dev4` (control, not blocked) |
| Current → target | v1.35.6+vmware.2 → v1.36.2+vmware.2 |
| First observed | 2026-08-27 UTC |
| Revised with class-ceiling analysis | 2026-09-01 UTC |

---

## Impact

This is not a single stuck cluster. If the mechanism below is correct, **every TMC-managed guest
cluster becomes permanently unupgradable once it reaches the ceiling of its ClusterClass**, at
every VKS generation boundary. A cluster can be walked up to its class ceiling through TMC and
never past it.

This deployment's operating model relies on TMC for provisioning, deprovisioning, and upgrade of
all guest clusters. The only escape currently available is an out-of-band edit of
`spec.topology.version` on the Supervisor, which bypasses the very control plane being validated
and is therefore not an acceptable workaround.

After upgrading VKS from 3.6.3 to 3.7 (which delivers VKr v1.36 and ClusterClass
`builtin-generic-v3.7.0`), the TMC console offers no upgrade for the managed cluster `dev1`, and
`tanzu mission-control cluster get` reports the cluster is already at the latest version. The
Supervisor advertises v1.36 correctly.

---

## Proposed mechanism

1. The Supervisor publishes a **flat** list of available releases into
   `vsphereoptions/options`, carrying **no ClusterClass association of any kind** (E3). v1.36 is
   in that list.
2. TMC therefore cannot be receiving a pre-filtered set — any class-based filtering happens on
   the TMC side, using the cluster's own `spec.topology.classRef`.
3. TMC appears to intersect that flat list with the `max-version-supported` label of the
   cluster's **current** class. For `dev1` — class `builtin-generic-v3.6.0`, ceiling `v1.35`,
   sitting at `v1.35.6` — the intersection is empty.
4. `VersionIsLatest` therefore resolves to `NoUpgradeVersions`.
5. `ClassRebaseNeeded` reports **the same reason**, `NoUpgradeVersions` (E4) — indicating it is
   derived from the candidate list rather than computed independently.

The result is a deadlock. Reaching v1.36 requires a rebase to `builtin-generic-v3.7.0`; the
rebase is only considered if a candidate above the current ceiling exists; the ceiling removes
exactly those candidates before the rebase check runs.

This predicts precisely what is observed: TMC brokers upgrades normally **within** a class window
and fails silently — with no error, no warning, and no unsupported-version message — at every
class boundary.

---

## Environment

| Component | Version | Note |
|---|---|---|
| TMC Self-Managed | 1.4.5 | `package-repository:1.4.5`, all PackageInstalls reconciled |
| vSphere Supervisor | v1.32.7+vmware.5-fips | 3 control-plane nodes |
| ESXi | v1.32.5-sph-cd37574 | 4 hosts |
| VKS | 3.7 | upgraded from 3.6.3 on 2026-08-26 23:42 UTC |
| TMC Supervisor Service ns | `svc-tmc-c9` | all 8 deployments 1/1 READY |
| Management cluster | `non-prod-mgr` | provisioner `tmc-sm`, vSphere Namespace `tmc-sm` |
| `dev1` (blocked) | v1.35.6+vmware.2 | class `builtin-generic-v3.6.0`, ceiling v1.35 |
| `dev4` (control) | v1.35.2+vmware.1 | class `builtin-generic-v3.7.0`, ceiling v1.36 |
| `tmc` (not TMC-managed) | v1.36.2+vmware.2 | hosts TMC SM itself; upgraded by direct edit |
| Intended target for `dev1` | v1.36.2+vmware.2 | vkr `v1.36.2---vmware.2-vkr.3` |

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

### E2 — ClusterClass version windows

The windows are carried as **labels** (`kubernetes.vmware.com/{min,max}-version-supported`), not
annotations. Captured live 2026-09-01:

```
NS                         NAME                     MIN     MAX     CREATED
tmc-sm                     builtin-generic-v3.1.0   v1.25   v1.32   2026-07-29T23:52:48Z
tmc-sm                     builtin-generic-v3.2.0   v1.27   v1.32   2026-07-29T23:52:48Z
tmc-sm                     builtin-generic-v3.3.0   v1.28   v1.32   2026-07-29T23:52:49Z
vmware-system-vks-public   builtin-generic-v3.1.0   v1.25   v1.32   2026-07-29T23:56:52Z
vmware-system-vks-public   builtin-generic-v3.2.0   v1.27   v1.32   2026-07-29T23:56:52Z
vmware-system-vks-public   builtin-generic-v3.3.0   v1.28   v1.32   2026-07-29T23:56:50Z
vmware-system-vks-public   builtin-generic-v3.4.0   v1.29   v1.33   2026-07-29T23:59:58Z
vmware-system-vks-public   builtin-generic-v3.5.0   v1.31   v1.34   2026-08-25T19:11:54Z
vmware-system-vks-public   builtin-generic-v3.6.0   v1.32   v1.35   2026-08-25T19:11:54Z
vmware-system-vks-public   builtin-generic-v3.7.0   v1.33   v1.36   2026-08-26T23:42:23Z
```

`dev1` sits on `builtin-generic-v3.6.0` at `v1.35.6` — **exactly at that class's ceiling.**

### E3 — The published option set contains v1.36 and carries no ClusterClass metadata

Read from the Supervisor control plane with `/etc/kubernetes/admin.conf` (this is the object TMC
consumes; it is not readable by a vSphere admin — see *Diagnostic access limitations*).

```
$ kubectl -n svc-tmc-c9 get vsphereoptions options -o yaml

spec.tkgServiceOptions.releases[].name, in publication order:
  v1.33.1+vmware.1-fips-vkr.2      v1.34.9+vmware.2-vkr.4
  v1.33.3+vmware.1-fips-vkr.1      v1.35.2+vmware.1-vkr.3
  v1.33.6+vmware.1-fips-vkr.2      v1.35.5+vmware.1-vkr.1
  v1.33.13+vmware.2-fips-vkr.4     v1.35.6+vmware.2-vkr.3
  v1.34.1+vmware.1-vkr.4           v1.36.1+vmware.4-vkr.5   <- present
  v1.34.2+vmware.2-vkr.2           v1.36.2+vmware.2-vkr.3   <- present, the intended target
  v1.34.8+vmware.1-vkr.1
```

A case-insensitive search of the entire object for `clusterclass`, `topology`, `rebase`,
`min-version`, and `max-version` returns **zero matches**. Each release entry carries only its
name and its core addon versions (CNI, CSI, CPI, etc.).

**This is the load-bearing finding.** The Supervisor-side render is correct and complete, and it
is class-agnostic. TMC receives every release including v1.36 with no indication of which
ClusterClass any of them belongs to. Any narrowing to an empty set is therefore performed by TMC,
against state TMC holds about the cluster — of which `classRef` is the obvious candidate.

### E4 — TMC computes an empty candidate list, and derives the rebase decision from it

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

TMC is not rejecting v1.36 on compatibility grounds — it never treated v1.36 as a candidate.
`ClassRebaseNeeded` citing `NoUpgradeVersions` as its own reason is the specific signal that the
rebase decision is downstream of the version list, not independent of it.

### E5 — Controlled pair: same Supervisor, same TMC, same VKr generation, different class

| | `dev1` | `dev4` |
|---|---|---|
| Kubernetes | v1.35.6+vmware.2 | v1.35.2+vmware.1 |
| ClusterClass | `builtin-generic-v3.6.0` | `builtin-generic-v3.7.0` |
| Class ceiling | **v1.35** | **v1.36** |
| At ceiling? | **yes** | no |
| v1.36 in option set | yes | yes |
| TMC offers upgrade | **no** | **yes** |

Both clusters are TMC-managed, in vSphere Namespace `tmc-sm`, under management cluster
`non-prod-mgr`, on the same Supervisor, against the same `vsphereoptions/options`. The only
material difference is the ClusterClass they are bound to, and with it the ceiling.

`dev4` live state, captured 2026-09-01:

```
$ kubectl -n tmc-sm get cluster dev4 -o jsonpath=...
created   = 2026-09-01T21:18:06Z
classRef  = builtin-generic-v3.7.0 (vmware-system-vks-public)
version   = v1.35.2+vmware.1
tkr label = v1.35.2---vmware.1-vkr.3
phase     = Provisioned
```

*Scope note:* `dev4` reaching v1.36 does **not** require a class rebase, so this pair confirms the
clamp is consistent with observed behaviour but does not by itself isolate the clamp from a
hypothetical "TMC is working correctly for dev4" explanation. See *What would falsify this*.

### E6 — The Supervisor overrides the requested ClusterClass to the latest supported

New clusters cannot be pinned to an older class. `dev4` was created from a manifest requesting
`builtin-generic-v3.6.0` and came up on `builtin-generic-v3.7.0`:

```
manifest (resources/dev4.yaml)   spec.topology.class     = builtin-generic-v3.6.0
live object                      spec.topology.classRef  = builtin-generic-v3.7.0
```

The same holds for the `tmc` cluster, whose manifest requested `builtin-generic-v3.4.0` at
`v1.33.6+vmware.1-fips` and which now reports `classRef: builtin-generic-v3.7.0`.

The admission webhook states this behaviour explicitly. Server-side dry-run, requesting
`builtin-generic-v3.6.0`:

```
$ kubectl -n tmc-sm apply --dry-run=server -f cluster-class-3.6.0.yaml
Warning: ClusterClass builtin-generic-v3.6.0 updated to the newest compatible
         ClusterClass builtin-generic-v3.7.0
```

The selection is keyed to the requested Kubernetes version, but `builtin-generic-v3.7.0`'s window
(v1.33–v1.36) spans every release in the option set, so no available VKr escapes it:

| Requested version, class 3.6.0 | Resulting classRef |
|---|---|
| v1.33.6+vmware.1-fips-vkr.2 | `builtin-generic-v3.7.0` |
| v1.34.9+vmware.2-vkr.4 | `builtin-generic-v3.7.0` |
| v1.35.6+vmware.2-vkr.3 | `builtin-generic-v3.7.0` |

**And the assignment is a one-way ratchet.** An existing cluster cannot be moved back down:

```
$ kubectl -n tmc-sm patch cluster dev4 --type=merge --dry-run=server \
    -p '{"spec":{"topology":{"classRef":{"name":"builtin-generic-v3.6.0"}}}}'
Warning: ClusterClass version cannot be downgraded. builtin-generic-v3.7.0
         ClusterClass will continue to be used
```

This matters three times over. It explains why newly created clusters are never blocked — they
always land on the newest class, with the highest ceiling. It means the blocked state can only be
reached the way `dev1` reached it: by existing before the newer class arrived. And it means the
blocked state **cannot be repaired from the Supervisor side either** — a cluster stranded below a
new class ceiling can be neither re-pinned nor rebuilt onto its old class, so once TMC declines to
offer the version, the only remaining lever is a direct `spec.topology.version` write (E7).

### E7 — ClusterClass rebase is a Supervisor-side effect of setting the version

The `tmc` cluster (which hosts TMC SM itself and is therefore not TMC-managed) was moved from
`v1.33.6+vmware.1-fips` to `v1.36.2+vmware.2` by editing `spec.topology.version` directly. The
upgrade succeeded and the class rebased on its own, from the requested 3.4.0 to 3.7.0 — crossing
from a class with a v1.33 ceiling to one with a v1.36 ceiling.

The Supervisor, the vKr, the ClusterClass, and cross-class rebase are all demonstrably
functional. **A consumer that simply writes the desired version gets the rebase for free.** TMC
does not need to orchestrate the rebase; it only needs to offer the version. It does not, because
of the clamp.

### E8 — The 1.4.4 precedent, and why it does not disprove the clamp

Under **TMC SM 1.4.4**, after a VKS 3.4.1 → 3.6.3 upgrade, TMC offered and successfully brokered
an upgrade of `dev1` to **v1.35.6 on `builtin-generic-v3.6.0`**. TMC's stored intent still records
the origin: `dev1`'s `run.tanzu.vmware.com/last-applied-configuration` contains
`"topology":{"version":"v1.33.6+vmware.1-fips-vkr.2"}` while the live cluster ran `v1.35.6`.

An earlier revision of this case treated that as proof that TMC crosses class ceilings, and used
it to rule the ceiling out. **That inference does not hold.** It assumes `dev1` was still on
`builtin-generic-v3.4.0` (ceiling v1.33) at the moment TMC computed the offer. What is actually
established is only the starting version and the end state — not the class in effect when the
candidate list was built. Given E7, the more likely sequence is that the VKS upgrade or an
intermediate version write rebased `dev1` to 3.6.0 first, after which TMC was offering a strictly
**within-ceiling** v1.35.6 and crossed nothing.

We flag this as a correction to our own earlier analysis, and as a question we cannot settle from
this side: **did 1.4.4 ever demonstrably offer a version above the current class ceiling?** If it
did not, then this may not be a 1.4.4 → 1.4.5 regression at all, but a long-standing gap that
went unnoticed because no cluster had previously sat exactly at its ceiling when a new class
arrived. Either way the defect stands; only its age is in question.

### E9 — Data reaches the agent; the management cluster is healthy

```
$ kubectl -n svc-tmc-c9 logs deploy/vsphere-resource-retriever --since=15m \
    | grep -ioE "kubernetesrelease|v1\.3[456]" | sort | uniq -c
    318 KubernetesRelease
     36 v1.34
     42 v1.35
     20 v1.36
```

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

### E10 — Reproducible from a cold start

`vsphere-resource-retriever` was restarted from the Supervisor control plane. A new pod came up
clean (new ReplicaSet hash, 0 restarts) and `dev1` remained blocked, with the condition actively
recomputed seconds before the query:

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

This is a steady-state computation, not accumulated or corrupted in-memory state.

---

## Secondary defect — `vsphereoptions/options` rewrite loop

**We no longer believe this is the mechanism of the upgrade block**, since E3 shows the published
object is correct and complete regardless of how often it is rewritten. It is reported separately
because a controller that never converges is a defect in its own right, and because it should be
excluded as a contributing factor rather than assumed harmless.

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

**The inputs are static; the render is not.** Sampling the renderer's inputs 11 seconds apart
returns byte-identical `resourceVersion`s, while the output is rewritten ~30 times in that window:

```
21:44:43 → 21:44:54, storagepolicyquota + namespace resourceVersions

svc-tkg-domain-c9     nfs-pool-1-policy-storagepolicyquota    11029  →  11029
svc-velero-domain-c9  nfs-pool-1-policy-storagepolicyquota    11068  →  11068
tmc-sm                nfs-pool-1-policy-storagepolicyquota 34516299  →  34516299
tmc-sm                vsan-default-storage-policy-...         37274  →  37274
ns/svc-tkg-domain-c9                                       34552816  →  34552816
ns/svc-velero-domain-c9                                    34554211  →  34554211
ns/tmc-sm                                                     14805  →  14805
```

Each render pass re-enumerates the same eight storage classes across four namespaces. If that
collection is assembled in nondeterministic order, every pass differs from the last and the
controller never converges.

**The loop is long-running.** The object's own metadata quantifies it independently of any log
sampling:

```
creationTimestamp: 2026-08-21T18:56:48Z
generation:        1012447        (read 2026-09-01)
```

That is ~1.01M generations over 15,560 minutes — a sustained average of **~65 writes per minute
for eleven days**, on an object whose content should be near-static.

Restarting the retriever does not clear it (E10): post-restart the loop resumed at 173 events/min
within six minutes.

A related candidate trigger: three ClusterClass **names exist in two namespaces simultaneously**
(E2 — `builtin-generic-v3.1.0` through `v3.3.0` in both `tmc-sm` and `vmware-system-vks-public`).
No cluster references the `tmc-sm` copies. Offered as a possible source of name-keyed collation
producing unstable output. Note the duplicates have existed since 2026-07-29 and TMC-brokered
upgrades succeeded after that date.

---

## Ruled out

- **Unsupported target version.** The 1.4.5 release notes state support for provisioning and
  attaching v1.36 clusters, and add lifecycle management for VKS 3.7 including VKr v1.36 and
  `builtin-generic-v3.7.0`. The interoperability matrix agrees.
- **Missing or unhealthy vKr.** Both v1.36.1 and v1.36.2 are `READY=True`, `COMPATIBLE=True` on
  the Supervisor (E1).
- **Resource discovery or rendering on the Supervisor.** Disproven by E3: v1.36 is present in the
  published `vsphereoptions/options` object.
- **Cross-class rebase being unsupported by the platform.** Disproven by E7: the `tmc` cluster
  rebased 3.4.0 → 3.7.0 automatically in response to a version write alone.
- **Management cluster connectivity or stale extensions.** Disproven by E9.
- **The `vsphereoptions` rewrite loop as the cause.** Downgraded to a secondary defect by E3 — the
  object's *content* is correct however often it is rewritten. Not fully excluded as a
  contributing factor; see question 3.
- **The 1.4.5 cluster-autoscaler known issue.** `dev1` does carry
  `addon.addons.kubernetes.vmware.com/cluster-autoscaler: automatic`, but `intent-agent` logs
  contain zero autoscaler references over 30 minutes, and no autoscaler reconciliation conflicts
  appear anywhere.
- **Cluster not actually managed.** `dev1` was `phase: Provisioned`, `Managed: TRUE`, and appeared
  in `tanzu mission-control cluster list` under management cluster `non-prod-mgr`.
- **Agent unhealthy or crash-looping.** All eight `svc-tmc-c9` deployments are 1/1; the retriever
  has 0 restarts across 3h+ uptime.

**No longer ruled out — the ClusterClass ceiling.** An earlier revision of this case listed this
as disproven, on the strength of E8. That reasoning was unsound and has been withdrawn; the
ceiling is now the primary hypothesis.

---

## What would falsify this

Stated explicitly so the hypothesis can be killed quickly if it is wrong:

- A TMC-managed cluster sitting **exactly at its class ceiling**, with a higher VKr present in
  `vsphereoptions/options`, that **is** offered an upgrade. This would disprove the clamp
  outright.
- TMC source or design documentation showing the candidate list is filtered by something other
  than the current `classRef` ceiling — in which case the question becomes what else empties it,
  given E3.
- Evidence that 1.4.4 demonstrably offered a version above a cluster's then-current class ceiling
  (see E8). This would not disprove the clamp in 1.4.5, but would confirm it as a regression
  rather than a long-standing gap.

Conversely, the observation that would most strengthen it: any TMC-managed cluster *below* its
class ceiling is offered upgrades normally, while every cluster *at* its ceiling reports
`NoUpgradeVersions` — regardless of class generation, VKr, or namespace.

---

## Reproduction

The blocked state can only be reached by a cluster that predates the newer ClusterClass, because
the Supervisor forces newly created clusters onto the latest class (E6). The sequence is:

1. vSphere Supervisor running VKS 3.6.x with TMC Self-Managed, and a TMC-managed guest cluster
   provisioned onto ClusterClass `builtin-generic-v3.6.0`.
2. Through TMC, upgrade that cluster to **v1.35.6** — i.e. all the way to `builtin-generic-v3.6.0`'s
   `max-version-supported` ceiling. (Upgrades below the ceiling work normally; this step is the
   one that arms the defect.)
3. Upgrade VKS 3.6.3 → 3.7, delivering VKr v1.36.x and `builtin-generic-v3.7.0` (ceiling v1.36).
   The existing cluster remains on `builtin-generic-v3.6.0`.
4. Confirm the Supervisor lists v1.36 as `READY` / `COMPATIBLE` (E1) and that v1.36 is present in
   `svc-tmc-c9/vsphereoptions/options` (E3).
5. Open the managed cluster in the TMC console — no upgrade option is presented.
6. Run `tanzu mission-control cluster get <cluster> -m <mgmt> -p <provisioner>` — observe
   `VersionIsLatest` / `NoUpgradeVersions` and `ClassRebaseNeeded` / `NoUpgradeVersions` (E4).
7. For contrast, create a new cluster in the same namespace at v1.35.x. It will land on
   `builtin-generic-v3.7.0` regardless of the class named in its manifest (E6), and TMC **will**
   offer it an upgrade (E5).

---

## What we need

1. **Is the upgrade-candidate list filtered by the `max-version-supported` label of the cluster's
   current ClusterClass?** If so, this is the defect: a cluster at its class ceiling can never be
   offered the version that would trigger the rebase to a higher-ceiling class.
2. **Is `ClassRebaseNeeded` computed from the candidate list, or independently?** Its reporting
   `NoUpgradeVersions` as its own reason (E4) suggests the former, which would make the two
   conditions circular.
3. **Is the `vsphereoptions/options` rewrite rate expected?** ~65 writes/min sustained over
   eleven days with static inputs is not, in our view. Can a consumer receiving that rate settle
   on a version set, and can it be excluded as a contributing factor?
4. **Is this a regression from 1.4.4, or a long-standing gap?** See E8 — we can no longer support
   the regression claim from our own evidence, and would like it settled from the TMC side.
5. **Is there a supported way to make TMC offer a cross-class upgrade**, or to force a re-sync of
   a management cluster's available Kubernetes versions, short of an out-of-band Supervisor edit?
6. **Are duplicate ClusterClass names across namespaces (E2) a known trigger** for the rewrite
   loop, and is it safe to remove the unreferenced `tmc-sm` copies?

---

## Diagnostic access limitations

Two checks are denied to `sso:Administrator@vsphere.local` against the Supervisor, because
`svc-tmc-c9` is a Supervisor Service namespace. Re-confirmed 2026-09-01:

```
$ kubectl -n svc-tmc-c9 get vsphereoptions options -o yaml
Error from server (Forbidden): vsphereoptions.run.tanzu.vmware.com "options" is forbidden:
User "sso:Administrator@vsphere.local" cannot get resource "vsphereoptions"
in API group "run.tanzu.vmware.com" in the namespace "svc-tmc-c9"

$ kubectl -n svc-tmc-c9 auth can-i patch deployments
no
$ kubectl -n svc-tmc-c9 auth can-i delete pods
no
```

Both gaps were closed using the Supervisor control-plane node's `/etc/kubernetes/admin.conf`: the
option set was read (E3) and the retriever was restarted (E10). The RBAC note is retained because
**E3 is the single most diagnostic artifact in this case and a customer cannot obtain it without
control-plane node access.**

---

## Provenance

- `dev1`, `dev2`, and `dev3` were test clusters and have since been deleted; **only `dev4`
  remains.** The `dev1` evidence (E4, E8, E9, E10, and the rewrite-loop measurements) is from the
  2026-08-27 collection and cannot be re-collected without rebuilding a cluster through the
  reproduction above.
- E2, E3, E5, and E6 were captured live on 2026-09-01 from the running system.
- `dev4`'s upgrade availability (E5) is operator-observed from the TMC console; the `tanzu` CLI
  output for `dev4` is not included in this revision.
- No restarts or configuration changes were applied during any measurement window.

*Case prepared 2026-08-27, revised 2026-09-01 · lab1 · TMC Self-Managed 1.4.5 · vSphere Supervisor
v1.32.7+vmware.5-fips.*

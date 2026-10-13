# Plan — Node-pool–staged VKr upgrade, 1.30 → 1.35 (TMC + VKS managed cluster)

**Status:** research / lab-validation plan. No customer cluster access; nothing here has been run
against the customer environment. Items marked **[VERIFY]** are assumptions about Cluster API (CAPI)
and TMC behaviour that must be confirmed in the lab before the plan is presented as a runbook.

## Goal

The customer runs one large TMC-managed VKS guest cluster (3 control-plane nodes, 20 workers) at
Kubernetes 1.30 on VKS 3.4.1 / TMC-SM 1.4.2. Target is Kubernetes 1.35, alongside TMC 1.4.2 → 1.4.4
and VKS 3.4.1 → 3.6.3.

The question: can worker upgrades be **staged by node pool**, so app teams can move workloads from
old-version nodes to new-version nodes in a controlled, manual way, instead of a single
cluster-wide rolling replacement?

## Answer in brief

- **Kubernetes version is cluster-wide.** On a ClusterClass (`v1beta1`) VKS cluster it lives in
  `spec.topology.version`; `machineDeployments[]` have no per-pool version field.
- **Timing is per-pool.** CAPI topology annotations let pools be held back and released one at a
  time:

  | Annotation | Set on | Effect |
  |---|---|---|
  | `topology.cluster.x-k8s.io/defer-upgrade: ""` | `spec.topology.workers.machineDeployments[].metadata.annotations` | Pool does not take the new version until the annotation is removed |
  | `topology.cluster.x-k8s.io/hold-upgrade-sequence: ""` | same | Holds this pool **and all pools after it** in the upgrade order |
  | `topology.cluster.x-k8s.io/upgrade-concurrency: "N"` | `Cluster` metadata | Number of pools allowed to roll in parallel once released |

- **Manual workload migration** is achieved with a blue/green pool pattern (new pool comes up at
  the new version, workloads are moved deliberately, old pool is retired).
- **Five minor hops are required on the control plane** (1.31, 1.32, 1.33, 1.34, 1.35). Whether
  workers must also take all five hops depends on CAPI behaviour — see Open question 1.

## Constraints already known from this engagement

These come from [vkr-upgrade-impediments.md](vkr-upgrade-impediments.md) and directly shape the
plan:

1. **TMC reconciles out manual patches to the Cluster resource.** Any annotation added with
   `kubectl` on the Supervisor is at risk of being reverted. **[VERIFY]** whether TMC's node pool
   spec can carry `metadata.annotations` natively; if not, the staged upgrade must be driven through
   the Supervisor Cluster API, which may mean de-registering the cluster from TMC for the duration.
2. **TMC does not offer VKr versions above the current ClusterClass ceiling.** VKr upgrades past
   the ceiling already have to be done via `spec.topology.version` on the Supervisor. This plan
   assumes Cluster API–driven upgrades regardless.
3. **VKS 3.5+ misconfiguration pre-checks** can block VKr upgrades (e.g. webhooks such as
   Gatekeeper); the bypass is a Cluster resource patch, which hits constraint 1 again. Budget a
   pre-check dry-run before every hop.
4. **ClusterClass rebase rolls every node.** VKS upgrade/rebase (`builtin-generic-v3.x`) can cause
   a full rollout with no Kubernetes version change. Align rebases with a version hop so the
   cluster is not rolled an extra time.
5. **Supervisor / vCenter version floors.** See supervisor-upgrade-version-parity notes — the
   customer's vCenter build decides which Supervisor versions (and therefore which VKS / VKr
   releases) are available at each step.

## Proposed node pool layout

Split the 20 workers into multiple pools before the first hop. Example:

| Pool | Replicas | Purpose |
|---|---|---|
| `np-a` | 5 | Canary / low-risk workloads — released first each hop |
| `np-b` | 5 | General workloads |
| `np-c` | 5 | General workloads |
| `np-d` | 5 | Critical / stateful workloads — released last |

Each pool carries a distinguishing node label (via `machineDeployments[].metadata.labels` or
ClusterClass variables) so workloads can be pinned with `nodeSelector` / affinity.

Re-pooling an existing single 20-node pool is itself a migration (new pools are created, workloads
moved, old pool deleted). Do this **once, before** the first version hop, and use it as the
rehearsal of the blue/green mechanics.

## Upgrade patterns

### Pattern A — Deferred pools, CAPI-managed drain (lower effort)

Per hop:

1. Pre-checks: VKS misconfiguration dry-run, PDB review, deprecated-API scan for the target
   minor, capacity headroom for `maxSurge`.
2. Annotate every pool with `defer-upgrade`.
3. Bump `spec.topology.version` to the next VKr. Control plane rolls; workers stay put.
4. Confirm control plane healthy at the new version.
5. Remove `defer-upgrade` from `np-a`. CAPI rolls the pool (create → cordon → drain → delete),
   honouring `strategy.rollingUpdate.maxSurge/maxUnavailable`, `nodeDrainTimeout`, and PDBs.
6. Soak; app teams validate.
7. Release `np-b`, `np-c`, `np-d` in turn (or set `upgrade-concurrency` to release in parallel).

App teams control **when** their pool moves, but not pod placement within the drain.

### Pattern B — Blue/green pools, manual migration (full control)

Per hop:

1. Pre-checks as above.
2. Defer all existing pools; bump `spec.topology.version`; control plane rolls.
3. Add a new pool (e.g. `np-a2`). **[VERIFY]** it is created at the new topology version.
4. App teams move workloads from `np-a` to `np-a2` on their own schedule — update
   `nodeSelector`/affinity, or `kubectl cordon` + `kubectl drain` specific nodes.
5. Scale `np-a` down as `np-a2` scales up (limits capacity overhead), then delete `np-a`.
6. Repeat for each pool. Next hop, alternate names back.

Costs: extra capacity while both pools exist; more Cluster spec churn (constraint 1 applies to
every pool add/remove).

## Hop sequence (skeleton — fill once the interop matrix is confirmed)

| Step | Platform change | K8s control plane | Workers (best case if Q1 = yes) | Workers (if Q1 = no) |
|---|---|---|---|---|
| 0 | Re-pool workers (Pattern B rehearsal) | 1.30 | 1.30 | 1.30 |
| 1 | — | 1.31 | 1.30 (deferred) | 1.31 |
| 2 | TMC 1.4.2 → 1.4.4 | 1.32 | 1.30 (deferred) | 1.32 |
| 3 | — | 1.33 | **roll → 1.33** | 1.33 |
| 4 | VKS → 3.5.x / 3.6.3 + Supervisor as required; ClusterClass rebase | 1.34 | 1.33 (deferred) | 1.34 |
| 5 | — | 1.35 | **roll → 1.35** | 1.35 |

Note: kubelet may be up to **3 minors** older than the API server (Kubernetes ≥ 1.28 skew policy),
so in the best case workers go 1.30 → 1.33 → 1.35 (two rollouts instead of five). Hop 2's TMC
upgrade and hop 4's VKS placement are placeholders — **[VERIFY]** against the Broadcom interop
matrix which VKS release first ships each VKr (1.34, 1.35) and whether TMC 1.4.4 lists them.

## Open questions (lab-validated)

1. **Does the control plane advance while pools are deferred?** I believe CAPI's topology
   controller holds the control plane version while MachineDeployments are upgrading, and possibly
   while they are only *pending* (deferred). If it holds, every pool must converge each hop and the
   "best case" column above is not available.
2. **Does TMC preserve the defer annotations?** Or reconcile them out (constraint 1)? Does TMC
   expose pool annotations in its own spec?
3. **Version of a newly added pool** while other pools are deferred.
4. **Does a ClusterClass rebase respect `defer-upgrade`?** Or does it roll deferred pools anyway?
5. **Pre-check interaction:** does the VKS 3.5+ pre-check evaluate deferred pools, and does a
   bypass persist across hops?
6. **Interop matrix:** VKS release per VKr (1.31–1.35), TMC-SM 1.4.4 support for 1.34/1.35,
   Supervisor/vCenter floors for the customer's vCenter build.

## Lab test plan

Environment: lab Supervisor / VKS guest cluster at the same starting versions as the customer
(see the version-parity notes).

| # | Test | Pass criteria | Answers |
|---|---|---|---|
| T1 | Create cluster with 2 pools (`np-a`, `np-b`), 2 workers each, at 1.30 | Healthy | baseline |
| T2 | Annotate both pools `defer-upgrade`; bump `spec.topology.version` → 1.31 | CP at 1.31, both pools at 1.30 | mechanism works |
| T3 | With pools still deferred, bump → 1.32 | CP rolls to 1.32 **or** is held (record the condition/message on `Cluster` / `TopologyReconciled`) | Q1 |
| T4 | Add pool `np-c` while others deferred | Record `np-c` node version | Q3 |
| T5 | Remove defer on `np-a` only | Only `np-a` rolls; `np-b` untouched | per-pool release |
| T6 | Trigger a TMC reconcile (edit something minor from TMC UI/CLI) | Annotations still present | Q2 |
| T7 | Pattern B: cordon/drain `np-b` workloads onto `np-c` manually, delete `np-b` | No unplanned evictions; PDBs honoured | manual migration |
| T8 | ClusterClass rebase with a deferred pool | Record whether the deferred pool rolls | Q4 |
| T9 | Run VKS pre-check dry-run with deferred pools present (VKS ≥ 3.5) | Record result / bypass behaviour | Q5 |

Capture for each test: `kubectl get cluster -o yaml` (conditions), `kubectl get md,ms,machines`,
`kubectl get nodes -o wide` from the guest cluster, and TMC cluster/nodepool state.

## Decision after the lab

- **Q1 = control plane advances while pools deferred:** use the best-case column (two worker
  rollouts); Pattern A or B per pool.
- **Q1 = control plane held:** per-hop staging only; five worker rollouts; recommend Pattern A for
  most pools and Pattern B only for workloads that need hand-placed migration.
- **Q2 = TMC strips annotations:** plan a TMC de-registration window for the upgrade (consistent
  with the existing pre-check bypass guidance), re-attach afterwards.

## References

- [vkr-upgrade-impediments.md](vkr-upgrade-impediments.md) — TMC reconcile and VKr ceiling constraints
- [references.md](references.md)
- Cluster API book — *Upgrading Clusters with a ClusterClass* (defer-upgrade / hold-upgrade-sequence / upgrade-concurrency)
- Kubernetes version skew policy — <https://kubernetes.io/releases/version-skew-policy/>

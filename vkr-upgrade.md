# VKr Upgrade process impediments and workarounds

The following is a description of design limitations of upgrading VKr on guest clusters managed by TMC through supervisor management clusters and VKS 3.5+.

There are three issues with TMC/VKS/Supervisor integration that preclude the ability to upgrade VKr without manual interventions:

## VKS misconfiguration pre-checks and bypass conflict with TMC

The misconfiguration pre-check functionality starting with VKS 3.5 may block VKr upgrades on a supervisor managed cluster. The idea is to protect clusters from breaking during an upgrade - running an upgrade (or dry-run) may uncover compatibility issues that need to be fixed before the upgrade can occur.

In some scenarios, such as running Gatekeeper, it may not be a compatibility issue, but still break the pre-check. At that point the pre-check must be bypassed such that the upgrade can continue. The bypass mechanism required patching the associated guest cluster's resource manifest.

See [this article about pre-checks and the recommended bypass method](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/overriding-software-misconfigurtion-checks-preventing-vks-cluster-upgrade.html).

The problem with TMC management of guest clusters is that patching the resource manifest, TMC will reconcile the change out. That blocks the ability to proceed with the upgrade for TMC managed clusters, and requires deleting the guest cluster registration from TMC, and proceeding with the bypass patching and upgrade directly through the supervisor Cluster API.

### Lab validation 2026-09-17 — this impediment did NOT reproduce on VKS 3.7.x

The scenario above was re-tested in lab1 and **did not reproduce**. On a TMC-managed guest cluster
running VKS 3.7.x, a TMC policy-deployed Gatekeeper did not block the VKr upgrade at all.

Test configuration:

| | |
|---|---|
| Cluster | `test10`, TMC-managed, cluster group `non-prod` |
| ClusterClass | `builtin-generic-v3.7.0` |
| VKr | `v1.35.6+vmware.2` -> `v1.36.2+vmware.2` |
| Gatekeeper | installed by a TMC custom-policy (`tmc-require-labels`, `enforcementAction: dryrun`) |

Result: `SystemChecksSucceeded` stayed **True** with Gatekeeper running and its admission webhook
intercepting Pods, and the **upgrade completed end to end through TMC** — no pre-check bypass
annotation, no unmanage/re-register, no Cluster API intervention. All three machines rolled to
`v1.36.2+vmware.2`, and the Gatekeeper deployment, its webhook, and the TMC agent all survived
the roll intact.

**Why TMC's own Gatekeeper is benign.** TMC's gatekeeper-operator generates the
ValidatingWebhookConfiguration's `rules` **from the policy's `targetKubernetesResources`**, and
configures the webhooks defensively:

- `validation.gatekeeper.sh` — **`failurePolicy: Ignore`**, namespaceSelector excluding
  `admission.gatekeeper.sh/ignore` and `gatekeeper-system`. Being `Ignore`, it structurally cannot
  block an operation even if Gatekeeper is down.
- `check-ignore-label.gatekeeper.sh` — `failurePolicy: Fail`, but scoped to `namespaces` only and
  excluding `gatekeeper-system`, `vmware-system-antrea`, `tkg-system` and `flow-aggregator`.

Note the direct coupling: a policy targeting ConfigMap yields a webhook intercepting only
`configmaps`; retargeting it to Pod yields one intercepting `pods`. Both were admitted.

**Mechanism — determined empirically 2026-09-17.** Follow-up probing on the same cluster
established how the check actually behaves. Each probe registered a dummy
ValidatingWebhookConfiguration with a dead backing service and varied one factor at a time,
watching `SystemChecksSucceeded`:

| Factor varied | Result |
|---|---|
| Webhook name `foo.bar.example.com` (unknown vendor) | not flagged |
| Webhook name `v1beta1.dynakube.webhook.dynatrace.com` | **flagged in ~3s** |
| Webhook name `validation.gatekeeper.sh` (separate config object) | **flagged** |
| `failurePolicy` `Ignore` vs `Fail` | no effect — flagged either way |
| `namespaceSelector` absent / excluding kube-system / Gatekeeper's own | no effect — flagged in all three |
| Backing service dead vs. live | no effect — flagged either way |
| Annotations `vksm.broadcom.com/managed`, `tmc.cloud.vmware.com/managed` | no effect — flagged either way |

Conclusions:

1. **The check is live and fast** — it re-evaluates within about 3 seconds of a webhook changing.
   A passing result is therefore meaningful, not a stale condition.
2. **It matches on a vendor denylist of webhook names.** An invented name is ignored entirely;
   the documented vendors (Gatekeeper, Kyverno, Rancher, k8tz, Dynatrace, Linkerd, OpenTelemetry)
   are matched. `failurePolicy`, `namespaceSelector` and backend health are all irrelevant to it —
   notably, a webhook that genuinely would deadlock an upgrade is treated no differently from a
   harmless one.
3. **TMC's own Gatekeeper install is already on the allowlist.** With a dummy
   `validation.gatekeeper.sh` registered under a different config object, the failure message read
   "1 webhook was detected" — counting only the dummy, while TMC's identically-named webhook in
   `gatekeeper-validating-webhook-configuration` went uncounted. The allowlist therefore keys on
   something more specific than the webhook name, most likely the ValidatingWebhookConfiguration
   object name.

**What this means for customers.** Impediment 1 does not bite for Gatekeeper deployed *by TMC
policy*, because VKS already allowlists that configuration. It still applies to a
**customer-deployed** Gatekeeper under a different ValidatingWebhookConfiguration name, and to
every other vendor on the list. So the impediment is narrowed, not eliminated — and the earlier
VKS 3.6.3 observation remains consistent with this.

**Still unresolved:** the exact annotation key for adding a webhook to the per-cluster allowlist.
The 3.7 release notes confirm the feature and the failure message references "Cluster's allowlist",
but the key is published in neither the release notes nor the override techdoc, is absent from the
`clusters.cluster.x-k8s.io` CRD schema and the ClusterClass variables, and is not present as an
annotation on a working cluster. Reading supervisor `validatingwebhookconfigurations` or CRDs
requires Supervisor control-plane node access — `administrator@vsphere.local` is denied both. Ask
GSS for the key, or recover it from a control-plane node.

A useful non-destructive probe for any re-test:

```bash
kubectl patch cluster <name> --type=merge \
  -p '{"spec":{"topology":{"version":"<target-vkr>"}}}' --dry-run=server
```

This runs full admission without persisting. Validate it with a deliberately bogus target version
first — that must be denied — so an "admitted" result is meaningful.

## TMC-deployed Gatekeeper trips the PodDisruptionBudget pre-check on small clusters

`SystemChecksSucceeded` covers more than the misconfigured-software (webhook) check. A separate
sub-check fails the upgrade when a PodDisruptionBudget would block a node drain, and on small
clusters TMC's own Gatekeeper deployment trips it before the webhook check is ever reported.

Applying any Gatekeeper-backed TMC policy causes the `gatekeeper-operator` (which ships with the
TMC agent in `vmware-system-tmc` and sits idle until a policy arrives) to deploy Gatekeeper with
**three** `gatekeeper-controller-manager` replicas and a PDB of `minAvailable: 1`. The deployment's
anti-affinity is only `preferredDuringSchedulingIgnoredDuringExecution` on `kubernetes.io/hostname`,
so on a cluster with a **single worker node** all three replicas schedule onto that one node.
Draining it would evict all three at once, taking `currentHealthy` to 0 and violating the PDB.

The cluster then reports:

```
SystemChecksSucceeded   False   NotSucceeded
  PodDisruptionBudgets blocking rollouts: gatekeeper-system/gatekeeper-controller-manager
```

Two things make this easy to misdiagnose:

- The PDB looks perfectly healthy when inspected at rest — `minAvailable: 1`, `currentHealthy: 3`,
  `disruptionsAllowed: 2`. The check is reasoning about what a *drain* would do, not about the
  current state.
- `SystemChecksSucceeded` reports **one failure message at a time**. While the PDB sub-check is
  failing it masks `MisconfiguredSoftwareChecks`, so the Gatekeeper webhook problem — the impediment
  described above — is not visible until the PDB issue is resolved. Do not conclude from a
  PDB-only message that the webhook check has passed.

**Confirmed in lab (2026-09-17):** scaling `md-0` from 1 to 2 workers cleared the failure and
`SystemChecksSucceeded` returned to True. The three replicas did not migrate immediately — the
anti-affinity is `IgnoredDuringExecution`, so they only redistributed (2/1 across the two workers)
once the upgrade's node roll forced rescheduling. The pre-check nonetheless passed as soon as a
second node existed, indicating it evaluates whether a drain *could* be satisfied rather than
current pod placement.

**Resolution:** scale the worker pool to at least two nodes so the replicas spread. With two workers
the 3 replicas split 2/1 and a drain still leaves one healthy, satisfying `minAvailable: 1`. Note
this leaves no margin; three workers gives one replica per node. Scale through TMC
(`tanzu mission-control cluster nodepool update`) rather than the supervisor, so TMC does not
reconcile the change out.

Because production clusters normally run multiple workers, this is primarily a hazard for small
test, edge, or single-worker footprints — but on exactly those clusters it blocks the upgrade
ahead of, and hidden behind, the better-known webhook impediment.

## VKS Auto Rebase behavior conflicts with TMC VKr ceiling constraints

VKS default behavior is such that when the VKS upgrades occur, the supervisor does not implicitly auto-rebase the clusterclasses in the supervised guest clusters.

You can read about that in the [Broadcom KB article here](https://knowledge.broadcom.com/external/article/439754/clusterclass-rebase-to-builtingenericv34.html), and, more broadly, about [clusterclass upgrades and auto-rebase functionality](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/updating-the-versioned-clusterclass.html).

When the operators decide to upgrade the VKr for a given cluster, they can update via the Cluster API through the cluster resource manifest `spec.topology.version` attribute to the latest supported VKr installed under the supervisor for which the VKS version is installed.

You can read about [VKr updates via cluster api here](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/updating-a-v1beta1-vks-cluster-by-editing-the-vkr-version.html).

During the application of the manifest update, supervisor will automatically upgrade the cluster resource's clusterclass to the appropriate version that supports the targeted VKr.

The problem when using TMC to manage the upgrades, either through CLI or UI, are that TMC will not show VKr upgrade candidates above the ceiling of the cluster class currently set for the target cluster resource, so, the operator is not allowed to upgrade the version of VKr through TMC, even through the supervisor would allow it.
This also forces upgrade through the Cluster API.

## Next Steps

1. Upgrade steps will be documented in a brief runbook excerpt form, meant for technical operators.
2. Broadcom PSO to discuss impact to customers and path forward to present as design defect/limitation to product management.
3. **Obtain the per-cluster webhook allowlist annotation key** (see impediment 1). This is now the
   single blocking unknown: the mechanism is understood and the allowlist demonstrably works, but
   the key is undocumented. Requires GSS or Supervisor control-plane node access. Once known,
   verify whether TMC reconciles the annotation out the same way it reconciles the blanket bypass
   annotation — if it does, the allowlist is no better than the existing workaround for
   TMC-managed clusters, which is the critical question for customers.
4. Optionally re-run on **VKS 3.6.x** to confirm the original failure mode and establish exactly
   what changed between 3.6 and 3.7.
5. Confirm whether the allowlist offers a supported alternative to the blanket
   `kubernetes.vmware.com/dangerous-skip-misconfigured-software-check-for-update` annotation. The
   annotation key is not published in the release notes and is not present in the
   `clusters.cluster.x-k8s.io` CRD schema; reading supervisor `validatingwebhookconfigurations`
   requires Supervisor control-plane node access, as `administrator@vsphere.local` is denied.
   If the allowlist is a cluster-spec field rather than an annotation, TMC may reconcile it the same
   way it reconciles the bypass annotation — which would need testing before recommending it.

# VKr Upgrade procedure for TMC Guest Workload Clusters

When dealing with VKr upgrades for TMC managed guest clusters,
it is important to understand the limitations imposed by TMC that will require additional steps for the upgrade.

You can read about them [here](#VKr-Upgrade-process-impediments-and-workarounds)

## High Level Procedure

1.  Verify whether dry-run of pre-check conditions are met.  This can be done by fetching the target cluster resource via the supervisor, reviewing the Status Conditions for `DryRunChecks failed: ...`.  If `DryRunChecks` show failed, proceed to step 3.

2.  If the VKr meets the ceiling requirement for the target cluster clusterclass version, TMC cli and UI will show the target VKr is available for upgrade.  The operator can upgrade through TMC as normal, and you are done with the upgrade procedure.

If not, [apply the upgrade througy the supervisor cluster api by updating the `spec.topology.version` to the target VKr](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/updating-a-v1beta1-vks-cluster-by-editing-the-vkr-version.html).  The upgrade should be complete successfully, including cluster class version rebasing and k8s cluster nodes updates to target VKr k8s versions. The TMC console view of the cluster should reflect the changes accordingly.  You are done with the upgrade procedure.

3.  As the VKS managed cluster pre-check dry runs fail, that requires pre-check bypass out-of-band of TMC.  This requires multiple steps:
    a. Unmanage the guest cluster from TMC - this results in TMC agent resources removed from the target cluster, but it is still managed by its management supervisor cluster.
       This is done to prevent TMC from reconciling (wiping) out the changes necessary to bypass the pre-checks in the target cluster.
       Monitor for the removal of the TMC agent components and namespace - if it does not complete, will require manual cleanup, otherwise will impede re-registration as part of step 3.e.
    b. [Bypass the the pre-checks via application of the following annotation to the target cluster resource manifest](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/overriding-software-misconfigurtion-checks-preventing-vks-cluster-upgrade.html):

        ```yaml
        annotations:
            kubernetes.vmware.com/dangerous-skip-misconfigured-software-check-for-update: ""
        ```
    c.  [Apply the upgrade througy the supervisor cluster api by updating the `spec.topology.version` to the target VKr](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/updating-a-v1beta1-vks-cluster-by-editing-the-vkr-version.html).  The upgrade should be complete successfully, including cluster class version rebasing and k8s cluster nodes updates to target VKr k8s versions.
    d.  Revert the pre-check bypass of step 3.b.
    e.  Through TMC UI or CLI, re-register the target cluster for TMC management - this can be done through TMC cli or UI, by selecting the target cluster in the management cluster "unmanaged" cluster list, and register it.  Monitor for the TMC agent components creation on the target cluster, and wait for deployments/pods to spin up.  The status of the cluster in the TMC UI will also reflect progress of agent component startup.

    You are now complete with the upgrade procedure.
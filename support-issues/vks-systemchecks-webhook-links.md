# VKS SystemChecksSucceeded / MisconfiguredSoftwareChecks — Reference Links

Context: VKS 3.6.3 workload cluster, ClusterClass builtin-generic-v3.4.0 -> v3.6.0,
VKR 1.33 -> 1.34. Upgrade denied by webhook
`capi.validating.tanzukubernetescluster.run.tanzu.vmware.com` because
`SystemChecksSucceeded` is not True.

Observed, in order:
  1. MisconfiguredSoftwareChecks failed: [validation.gatekeeper.sh] out of [1]
  2. MisconfiguredSoftwareChecks failed: [v1beta1.dynakube.webhook.dynatrace.com,
     v1beta2.dynakube.webhook.dynatrace.com, v1beta3.dynakube.webhook.dynatrace.com] out of [4]

URLs below are on their own lines so they survive line wrapping.


## 1. Primary KB — the exact error

VKS Cluster Upgrade Fails with "update cannot be initiated ... SystemChecksSucceeded
condition is not True". Covers both the PDB and third-party webhook variants. Lists the
detected webhook vendors and gives the back-up / delete / upgrade / restore procedure.

https://knowledge.broadcom.com/external/article/433183/vks-cluster-upgrade-fails-with-update-ca.html


## 2. Gatekeeper deadlock KB — why this one is the real hazard

Supervisor clusters fail to upgrade due to Gatekeeper; webhook intercepts kapp-controller
PackageInstall, call times out, CNI images never pull. Symptoms: new control plane nodes
NotReady, antrea-agent and vsphere-csi-node in ImagePullBackOff. Stated resolution for
that stranded state is "contact Broadcom support".

https://knowledge.broadcom.com/external/article/323447/vsphere-supervisor-kubernetes-clusters-f.html


## 3. Official override procedure

Overriding Software Misconfiguration Checks Blocking VKS Cluster Upgrade. Documents the
annotation kubernetes.vmware.com/dangerous-skip-misconfigured-software-check-for-update
on the Cluster object, and describes the two sub-checks (MisconfiguredSoftwareChecks and
the 24-hour DryRunChecks).

https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/overriding-software-misconfigurtion-checks-preventing-vks-cluster-upgrade.html

Note: the "/latest/" form of that URL 301-redirects to the 9-0 path above. Use the 9-0 URL.


## 4. General third-party webhook / CNI interaction KB

vSphere Workload Cluster nodes recreating or upgrade stuck — Antrea/Calico not running
due to third party webhook. Background for why this pre-check exists.

https://knowledge.broadcom.com/external/article/387563/vsphere-kubernetes-cluster-nodes-continu.html


## 5. VKS 3.7 release notes — per-cluster webhook allowlist

3.7.0 adds a per-cluster allowlist of webhook names to exclude from the
misconfigured-software check, avoiding the blanket "dangerous-skip" annotation. Release
notes confirm the feature but do not publish the exact annotation key — ask GSS or check
the 3.7 admin guide.

https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-release-notes/vmware-tanzu-kubernetes-grid-service-37-release-notes.html


## 6. VKS 3.6 release notes — where the webhook check was introduced

https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-release-notes/vmware-tanzu-kubernetes-grid-service-36-release-notes.html


## 7. Related PDB KB — same condition, other sub-check

After installing VKS 3.5.0 guest cluster cannot be upgraded with
"SystemChecksSucceeded condition is not True. Message: PodDisruptionBudgets blocking rollouts".

https://knowledge.broadcom.com/external/article/422362/after-installing-vks-350-guest-cluster-c.html


## Non-Broadcom, needed for the Gatekeeper fix

Gatekeeper — Exempting Namespaces (admission.gatekeeper.sh/ignore label,
--exempt-namespace flag, Config excludedNamespaces):

https://open-policy-agent.github.io/gatekeeper/website/docs/exempt-namespaces/

Gatekeeper issue 3675 — namespaceSelector has no effect unless the webhook rule sets
scope: Namespaced (Kubernetes defaults scope to "*"):

https://github.com/open-policy-agent/gatekeeper/issues/3675

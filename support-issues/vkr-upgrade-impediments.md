# VKr Upgrade process impediments and workarounds

The following is a description of design limitations of upgrading VKr on guest clusters managed by TMC through supervisor management clusters and VKS 3.5+.

There are two issues with TMC/VKS/Supervisor integration that preclude the ability to upgrade VKr without manual interventions:

## VKS misconfiguration pre-checks and bypass conflict with TMC

The misconfiguration pre-check functionality starting with VKS 3.5 may block VKr upgrades on a supervisor managed cluster.
The idea is to protect clusters from breaking during an upgrade - running an upgrade (or dry-run) may uncover compatibilty issues
that need to be fixed before the upgrade can occur.

In some scenarios, such as running Gatekeeper, it may not be a compatibility issue, but still break the pre-check.
At that point the pre-check must be bypassed such that the upgrade can continue.
The bypass mechanism required patching the associated guest cluster's resource manifest.

See [this article about pre-checks and the recommended bypass method](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/overriding-software-misconfigurtion-checks-preventing-vks-cluster-upgrade.html).

The problem with TMC management of guest clusters is that patching the resource manifest, TMC will reconcile the change out.
That blocks the ability to proceed with the upgrade for TMC managed clusters, and requires deleting the guest cluster registration from TMC,
and proceeding with the bypass patching and upgrade directly through the supervisor Cluster API.

## VKS Auto Rebase behavior conflicts with TMC VKr ceiling constraints

VKS default behavior is such that when the VKS upgrades occur, the supervisor does not implicitly auto-rebase the clusterclasses
in the supervised guest clusters.

You can read about that in the [Broadcom KB article here](https://knowledge.broadcom.com/external/article/439754/clusterclass-rebase-to-builtingenericv34.html),
and, more broadly about [clusterclass upgrades](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/updating-the-versioned-clusterclass.html) and [auto-rebase functionality](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api/using-the-versioned-clusterclass/auto-rebasing-of-vks-clusters.html).

When the operators decide to upgrade the VKr for a given cluster, they can update via the Cluster API through the cluster resource manifest
`spec.topology.version` attribute to the latest supported VKr installed under the supervisor for which the VKS version is installed.

You can read about [VKr updates via cluster api here](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/updating-tkg-service-clusters/updating-a-v1beta1-vks-cluster-by-editing-the-vkr-version.html).

During the application of the manifest update, supervisor will automatically upgrade the cluster resource's clusterclass to the appropriate version that supports the targeted VKr.

The problem when using TMC to manage the upgrades, either through CLI or UI, are that TMC will not show VKr upgrade candidates above the ceiling of the cluster class
currently set for the target cluster resource, so, the operator is not allowed to upgrade the version of VKr through TMC, even through the supervisor would allow it.

This also forces upgrade through the Cluster API.

## Next steps

1. Upgrade steps will be documented in a brief runbook excerpt form, meant for technical operators.
2. Broadcom PSO to discuss impact to customers and path forward to present as design defect/limitation to product management.

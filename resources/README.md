# Cluster resources

Manifests and helpers for standing up the `tmc` guest cluster on the Supervisor.

| File | Purpose |
| --- | --- |
| `tmc-cluster.yaml` | ClusterClass-based guest cluster (`tmc`) provisioned into the `tmc-sm` vSphere Namespace. |
| `setup-namespace.sh` | Create and verify the `tmc-sm` vSphere Namespace before applying the manifest. |
| `sm_values.yaml` | TMC Self-Managed install values. |
| `agentconfig.yaml`, `agentinstall.yaml`, `agent-uninstall.yaml` | TMC agent lifecycle for the guest cluster. |

## Prerequisite: the `tmc-sm` vSphere Namespace

`tmc-cluster.yaml` provisions into `metadata.namespace: tmc-sm`. That is a
**vSphere Namespace** — a Supervisor (Workload Management) object, **not** a
regular vCenter inventory folder. This is why there is no option to create it in
the normal vCenter inventory views; it lives under **Workload Management**.

The namespace must exist **and** have the storage policy, VM classes, content
library, and permissions the manifest references bound to it. Creating a bare
namespace is not enough — the Cluster will fail to provision without them.

### What the manifest requires

| Requirement | Value | Where the manifest uses it |
| --- | --- | --- |
| Namespace name | `tmc-sm` | `metadata.namespace` |
| Storage policy (control-plane data) | `management-storage-policy-regular` | control-plane containerd volume `storageClass` |
| Storage policy (workers + defaults) | `vsan-default-storage-policy` | cluster `storageClass`, worker containerd volume, guest `defaultStorageClass` |
| VM class | `best-effort-large` | control plane + worker `vmClass` overrides |
| TKR | `v1.33.6+vmware.1-fips` | `topology.version` / `tkr` label |

Both storage policies must be bound to the `tmc-sm` namespace — the control
plane's containerd data volume lands on `management-storage-policy-regular`;
node boot disks, worker data volumes, and the guest cluster's default
StorageClass all use `vsan-default-storage-policy`.

### Option A — vSphere Client (recommended)

1. vSphere Client → menu (☰) → **Workload Management**.
2. **Namespaces** tab → **New Namespace**.
3. Select the **Supervisor** on the target vCenter cluster.
4. **Name** = `tmc-sm` (DNS-1123: lowercase, hyphens ok) → **Create**.
5. On the namespace summary page, configure:
   - **Storage** → add both `management-storage-policy-regular` and `vsan-default-storage-policy`.
   - **VM Service** → add VM class `best-effort-large`.
   - **Content Library** → add the TKR library providing `v1.33.6+vmware.1-fips`.
   - **Permissions** → add the identity/group you use with `kubectl` (**Can edit**).

### Option B — CLI helper

`setup-namespace.sh` logs in (optional), creates the namespace, and verifies the
storage class, VM class, and TKR are available to it. Storage/VM/content-library
binding still has to be done from the vCenter side (Option A) — the script
reports what is missing so you know what to finish in the UI.

```bash
# Already logged in to the Supervisor:
resources/setup-namespace.sh

# Log in first, then set up (prompts for password):
resources/setup-namespace.sh <supervisor-vip>

# Non-default admin user:
SUPERVISOR_USER=administrator@vsphere.local \
  resources/setup-namespace.sh <supervisor-vip>
```

The script exits non-zero if any prerequisite is missing, so it is safe to gate
a provisioning step on it.

## Apply the cluster

Once the namespace is ready:

```bash
kubectl apply -f resources/tmc-cluster.yaml
kubectl get cluster tmc -n tmc-sm -w
```

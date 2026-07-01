# Monitoring scripts

Convenience scripts for the before/after state checkpoints described in the root
[`README.md` §4](../README.md#4-state-checkpoints-before-and-after).

| Script | Purpose |
| --- | --- |
| `snapshot-cluster.sh <before\|after> [output-root]` | Capture a full state snapshot of the currently-active kube-context. Run once per cluster (TMC SM and each guest) per label. |
| `diff-snapshots.sh <kube-context> [output-root]` | Diff a cluster's `before` snapshot against its `after`. |

## Usage

```bash
# BEFORE the upgrade — for each cluster, activate its context then:
kubectl config use-context <tmc-sm-context>
scripts/snapshot-cluster.sh before
kubectl config use-context <guest-context>
scripts/snapshot-cluster.sh before

# ... run the upgrade and verification ...

# AFTER — same clusters, same contexts:
scripts/snapshot-cluster.sh after     # per context

# Compare, per cluster:
scripts/diff-snapshots.sh <tmc-sm-context>
scripts/diff-snapshots.sh <guest-context>
```

Output lands in `snapshots/<kube-context>/<before|after>/` (git-ignored). Pass a
second argument to either script to use a different output root.

## What gets captured

Per snapshot directory:

| File | Dimension |
| --- | --- |
| `repositories.txt`, `packages-installed.txt`, `pkgr.txt`, `pkgi.txt` | Tanzu repos / installed packages / versions |
| `pkgi-constraints.txt`, `pkgi-status.txt` | PackageInstall version constraints and reconcile status |
| `component-versions.txt` | Explicit version matrix for cert-manager, Contour, fluxcd, velero — package version **and** runtime image tag |
| `nodes.txt` | Node states |
| `workloads.txt`, `pod-images.txt` | deploy/daemonset/statefulset/cronjob/job/pods + images |
| `crd-versions.txt` | CRD served & storage versions |
| `apiservices.txt`, `api-resources.txt`, `api-resources.err` | APIService availability + discovery health |
| `flux-resources.txt` | Flux CR Ready state + revisions |
| `webhooks.txt` | Validating / mutating admission webhooks |
| `contour-httpproxy.txt`, `cert-manager.txt` | Guest component health, where installed |

**The loudest signal:** a non-empty `api-resources.err` mentioning
`*.toolkit.fluxcd.io` (or any group) is the discovery break behind the silent CD
failure — see root [`README.md` §7](../README.md#7-the-continuous-delivery--flux-risk).
`snapshot-cluster.sh` echoes it to the terminal when it happens.

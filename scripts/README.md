# Monitoring scripts

Convenience scripts for the before/after state checkpoints described in the root
[`README.md` §4](../README.md#4-state-checkpoints-before-and-after).

| Script | Purpose |
| --- | --- |
| `snapshot-cluster.sh <before\|after> [output-root]` | Capture a full state snapshot of the currently-active kube-context. Run once per cluster (TMC SM and each guest) per label. |
| `diff-snapshots.sh <kube-context> [output-root]` | Diff a cluster's `before` snapshot against its `after` (raw `diff -ru`). |
| `assess-snapshots.sh [kube-context ...]` | Rule-based post-upgrade assessment: a pass/review/finding table per cluster + overall verdict, as markdown. No args → every cluster with both snapshots. |

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

# Or generate the assessment report across all captured clusters at once:
scripts/assess-snapshots.sh > snapshots/upgrade-assessment-auto.md
```

> `snapshots/upgrade-assessment.md` is the curated, hand-reviewed narrative;
> write the machine-generated report to a distinct name (`-auto.md`) so it does
> not overwrite it.

## Assessment report

`assess-snapshots.sh` reduces the raw before/after diff to a verdict, encoding
the "What each diff should show" expectations from root
[`README.md` §4.3](../README.md#43-what-each-diff-should-show). Each dimension is
classified:

- **PASS** — expected state, or an expected move landed cleanly.
- **REVIEW** — changed or failing in a way a human should eyeball. Includes
  pre-existing failures (flagged as such, not blamed on the upgrade) and
  expected-but-unverifiable moves like constraint bumps.
- **FINDING** — the upgrade appears to have broken something.

It is deterministic (no LLM) and best-effort (a missing snapshot file is
skipped). It exits non-zero only when there is a real **FINDING**, so it can gate
an automated pipeline. It normalizes away clock/whitespace churn (AGE columns,
table re-padding) so only substantive changes register. Judgment it cannot make
is surfaced as REVIEW rather than silently passed.

Output lands in `snapshots/<kube-context>/<before|after>/` (git-ignored). Pass a
second argument to either script to use a different output root.

## What gets captured

Per snapshot directory:

| File | Dimension |
| --- | --- |
| `repositories.txt`, `packages-installed.txt`, `pkgr.txt`, `pkgi.txt` | Tanzu repos / installed packages / versions |
| `pkgr-detail.txt` | PackageRepository substance — imgpkgBundle **image/tag**, reconcile status, owner (the `describe pkgr tanzu-standard` fields `-o wide` hides; on guests the 1.4.4 upgrade repoints tanzu-standard at the TMC-SM-mirrored catalog) |
| `pkg-catalog.txt` | Offered `PackageMetadata` names — makes the `*.tanzu.vmware.com` (tkg) → `*.kubernetes.vmware.com` (vks) offerings swap visible |
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

# TMC Self-Managed 1.4.2 → 1.4.4 Upgrade

The core runbook for upgrading Tanzu Mission Control Self-Managed (TMC SM) from
**1.4.2 to 1.4.4**, including the Tanzu Standard Package Repository bump
(**v2025.6.18 → v2026.1.21**) that rides along with it and its impact on managed
(guest) clusters.

> **Scope.** This project covers the upgrade only. It assumes the prior
> migration work (source → self-managed stack cutover) is complete and the
> environment is in a known-good, fully-migrated state. Migration tooling lives
> separately in `../tmc-migration-scripts`.

**Environment of record:** lab1 (`harbor.lab1.mmtm.ai`, air-gapped, self-signed
Harbor). Commands and paths below reflect that lab; substitute your own
Harbor host, project, and ECR-mirror path where shown.

---

## Contents

1. [The one thing to understand first](#1-the-one-thing-to-understand-first)
2. [Prerequisites](#2-prerequisites)
3. [Pre-upgrade preparation](#3-pre-upgrade-preparation)
4. [State checkpoints (before and after)](#4-state-checkpoints-before-and-after)
5. [Running the upgrade](#5-running-the-upgrade)
6. [Verification](#6-verification)
7. [The Continuous Delivery / Flux risk](#7-the-continuous-delivery--flux-risk)
8. [Contour on guest clusters](#8-contour-on-guest-clusters)
9. [Velero / Data Protection](#9-velero--data-protection)
10. [Troubleshooting: guest `tanzu-standard` ReconcileFailed](#10-troubleshooting-guest-tanzu-standard-reconcilefailed)
11. [Companion documents & references](#11-companion-documents--references)

---

## 1. Two Upgrades in One

The installer presents the upgrade as a single operation. It is really **two
upgrades with two different zones**, and the second one silently reaches
into every managed guest cluster:

| # | What ships | Repo on the **TMC SM** cluster | Repo on **each managed guest** |
| --- | --- | --- | --- |
| 1 | TMC SM platform (control-plane services) | `tanzu-mission-control-packages` (`tmc-local`) → **1.4.4** | _not present_ |
| 2 | Tanzu Standard Package Repository (Contour, cert-manager, **fluxcd** source/kustomize/helm controllers, external-dns, Harbor, Prometheus, Grafana, …) | `tanzu-standard` (`tkg-system`) → **v2026.1.21** | `tanzu-standard` (`tkg-system`) → **v2026.1.21** |

The guest-side `tanzu-standard` `PackageRepository` is **TMC-owned** (annotated
`tanzu.vmware.com/owner: tmc`). During the SM upgrade, TMC rewrites its bundle
URL from `:v2025.6.18` to `:v2026.1.21` on every guest — the installer UI gives
no signal that guests are being touched.

```text
        ┌────────────────────────────────────────────┐
        │            TMC SM target cluster            │
        │  pkgr tanzu-mission-control-packages ─ 1.4.4│
        │  pkgr tanzu-standard            ─ v2026.1.21│
        │  pkgi tmc (tmc.tanzu.vmware.com)      1.4.4  │
        └───────────────────┬─────────────────────────┘
                            │ TMC pushes new URL into each
                            │ guest's tanzu-standard PackageRepository
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ guest #1 │  │ guest #2 │  │ guest #N │
        │ tanzu-   │  │ tanzu-   │  │ tanzu-   │
        │ standard │  │ standard │  │ standard │
        │ →v2026.  │  │ →v2026.  │  │ →v2026.  │
        │  1.21    │  │  1.21    │  │  1.21    │
        └──────────┘  └──────────┘  └──────────┘
```

**Important note:** the `v2026.1.21` bundle must already
be staged in Harbor at the path the guests resolve **before** the SM upgrade is
initiated. Otherwise every guest flips to `ReconcileFailed` (`NOT_FOUND`) the
moment TMC pushes the new URL, and stays there until you push the bundle. We hit
exactly this in lab1 — see [§10](#10-troubleshooting-guest-tanzu-standard-reconcilefailed).

---

## 2. Prerequisites

- TMC SM 1.4.2 running and healthy; migration complete.
- Access to the extracted TMC SM **1.4.4** release bundle (`tmc-sm` tooling).
- A **Linux jumpbox** to run `tmc-sm` and `imgpkg` from — the `tmc-sm` installer
  is **not supported on macOS**, so all `tmc-sm` steps (push-images, console/UI,
  install) must run there, with access to Broadcom's registry and/or Harbor.
- Broadcom support-portal credentials for `projects.packages.broadcom.com`.
- Harbor CA cert on hand for `imgpkg --registry-ca-cert-path` (self-signed lab).
- The **v2026.1.21 release notes** for the `fluxcd-*` packages, `contour`, and `cert-manager`
  — component-version deltas, package renames (the 1.4.3 rebrand known-issue),
  and any CRD storage-version changes. **Do not start Phase B without them.**

> If this is a fresh install rather than an upgrade, the CA-material prep for
> `serverTLS.clusterIssuer.caSecret` is documented in
> `tmc-upgrade-considerations.md` ("Pre-install: CA materials"). It is not part
> of the 1.4.2 → 1.4.4 upgrade path and is out of scope here.

---

## 3. Pre-upgrade preparation

### 3.1 Stage the Tanzu Standard bundle into Harbor (do this first)

Stage `tanzu-standard:v2026.1.21` at the path mirroring the AWS ECR layout TMC
SM stamps into guest `PackageRepository` objects:

```text
<harbor>/<project>/<ecr-mirror-path>/packages/standard/repo:v2026.1.21
```

lab1 example:
`harbor.lab1.mmtm.ai/tmc-sm/498533941640.dkr.ecr.us-west-2.amazonaws.com/packages/standard/repo:v2026.1.21`

**Source:** `projects.packages.broadcom.com/tkg/packages/standard/repo:v2026.1.21`
(fallback: `.../tanzu_kubernetes_grid/packages/standard/repo:v2026.1.21`).
Requires `docker login projects.packages.broadcom.com`.

Air-gapped two-step copy (validated in lab1):

```bash
# Step 1 — host with Broadcom registry access:
imgpkg copy \
  -b projects.packages.broadcom.com/tkg/packages/standard/repo:v2026.1.21 \
  --to-tar tanzu-standard-v2026.1.21.tar          # ~8–12 GB

# Step 2 — move tar to a host with Harbor access, then:
imgpkg copy \
  --tar tanzu-standard-v2026.1.21.tar \
  --to-repo harbor.lab1.mmtm.ai/tmc-sm/498533941640.dkr.ecr.us-west-2.amazonaws.com/packages/standard/repo \
  --registry-ca-cert-path /path/to/harbor-ca.crt
```

> **Alternative (safest):** re-run `./tmc-sm push-images harbor …` from the
> extracted 1.4.4 bundle. It pushes the standard-repo bundle alongside
> everything else 1.4.4 needs — use this if there's any doubt about what else
> may not have been pushed during upgrade prep.
>
> **TLS note.** For a self-signed Harbor use `--registry-ca-cert-path` (keeps
> verification on). `--registry-verify-certs=false` also works (lab/dev only).
> `--registry-insecure` is the wrong flag — that's for plaintext HTTP.

Validate the artifact in the Harbor UI before proceeding.

### 3.2 Inventory every CD-enabled guest

Run against each guest with TMC CD enabled and **save the output** — this is the
"did anything actually change?" baseline you'll diff against after the upgrade:

```bash
# Are the fluxcd-* packages installed via the Tanzu Standard repo?
# (fluxcd-source-controller / fluxcd-kustomize-controller / fluxcd-helm-controller)
tanzu package installed list -A | grep -i flux

# Current controller image tags
kubectl get deploy -A -l app.kubernetes.io/part-of=flux -o wide

# CRD storage versions — these are what changes underneath you
for crd in helmreleases.helm.toolkit.fluxcd.io \
           kustomizations.kustomize.toolkit.fluxcd.io \
           gitrepositories.source.toolkit.fluxcd.io \
           helmrepositories.source.toolkit.fluxcd.io \
           ocirepositories.source.toolkit.fluxcd.io \
           helmcharts.source.toolkit.fluxcd.io \
           buckets.source.toolkit.fluxcd.io; do
  echo "=== $crd ==="
  kubectl get crd $crd -o jsonpath='{.spec.versions[?(@.storage)].name}{"\n"}' 2>/dev/null
done

# Non-TMC Flux objects (anything unexpected)
kubectl get gitrepositories,kustomizations,helmreleases -A
```

### 3.3 Choose a Flux strategy per guest

Decide before Phase B how each CD-enabled, `fluxcd-*`-bearing guest will be
handled — see the decision tree in [§7](#7-the-continuous-delivery--flux-risk).
If you choose the "disable TMC CD before, re-enable after" option, disable it
now.

Then capture the **before** snapshot per [§4](#4-state-checkpoints-before-and-after)
as the last thing before you start the upgrade.

---

## 4. State checkpoints (before and after)

Capture an identical state snapshot **immediately before** the upgrade and
**again after** verification, then diff the two. Run it against the **TMC SM
cluster** and **every managed guest** (switch kube-context between runs). The
`tanzu` commands assume a matching active `tanzu` context; the `kubectl`
commands are sufficient on their own if the `tanzu` CLI isn't wired to a guest.

The snapshot captures three primary dimensions **plus** the API-surface and
reconcile-status signals a version/image diff alone would miss — the Flux
failure mode ([§7](#7-the-continuous-delivery--flux-risk)) and its cousins:

1. **Tanzu repositories, packages, and versions** — the whole point of the
   upgrade; proves what moved (and confirms `:v2026.1.21` / 1.4.4 landed). Plus
   each package's reconcile **status**, because a `PackageInstall` can report the
   new version while its reconcile is actually failing.
2. **Node states** — catches guest TKR/kubelet rolls and any node that goes
   `NotReady` during the agent/package reconcile.
3. **Workloads** — deployments, daemonsets, statefulsets, cronjobs, jobs, pods —
   plus their images, which is where component version bumps actually surface.
4. **API surface** — CRD served/storage versions and APIService/discovery
   health. A storage-version move (`*.toolkit.fluxcd.io`, `projectcontour.io`, …)
   is invisible in package-version output but is exactly what silently breaks
   consumers; `kubectl api-resources` stderr catches the `unable to retrieve the
   complete list of server APIs` error directly.
5. **Reconcile truth** — Flux CR (`GitRepository` / `Kustomization` /
   `HelmRelease`) `Ready` state and revisions, and the admission webhooks that a
   package bump can silently rewrite.
6. **Guest component health** (where installed) — Contour `HTTPProxy` validity,
   cert-manager `Certificate` / `ClusterIssuer` readiness.
7. **Named component versions** — an explicit **cert-manager / Contour / fluxcd /
   velero** matrix, each pinned two ways: the resolved `PackageInstall` version
   _and_ the actual runtime container image tag (authoritative). velero is
   tracked by image tag only — TMC **Data Protection** deploys it outside the
   Standard repo, so it has no `PackageInstall` to read a version from.

### 4.1 Take a snapshot

Use [`scripts/snapshot-cluster.sh`](scripts/snapshot-cluster.sh) — run it with
the target cluster's kube-context active, once per cluster for each label:

```bash
scripts/snapshot-cluster.sh before      # ... later: scripts/snapshot-cluster.sh after
```

It's best-effort (a missing CLI or absent resource type is skipped, not fatal)
and writes one directory per cluster and label,
`snapshots/<kube-context>/<label>/`, containing:

| File(s) | Captures |
| --- | --- |
| `repositories.txt`, `packages-installed.txt`, `pkgr.txt`, `pkgi.txt` | Tanzu repos, installed packages, versions |
| `pkgi-constraints.txt`, `pkgi-status.txt` | PackageInstall version constraints and reconcile status |
| `component-versions.txt` | Explicit cert-manager / Contour / fluxcd / velero matrix — package version + runtime image tag (#7) |
| `nodes.txt` | Node states |
| `workloads.txt`, `pod-images.txt` | deploy/daemonset/statefulset/cronjob/job/pods + images |
| `crd-versions.txt` | CRD served & storage versions (#1) |
| `apiservices.txt`, `api-resources.txt`, `api-resources.err` | APIService availability + discovery health; `.err` catches the `unable to retrieve the complete list of server APIs` error (#2) |
| `flux-resources.txt` | Flux CR `Ready` state + revisions (#3) |
| `webhooks.txt` | Validating / mutating admission webhooks (#4) |
| `contour-httpproxy.txt`, `cert-manager.txt` | Guest component health where installed (#5) |

### 4.2 Capture and diff

Capture `before` on every cluster as the last step before the upgrade, `after`
once verification is done, then diff per cluster with
[`scripts/diff-snapshots.sh`](scripts/diff-snapshots.sh):

```bash
scripts/snapshot-cluster.sh before      # per cluster, before the upgrade
# ... run the upgrade + verification ...
scripts/snapshot-cluster.sh after       # per cluster, after

scripts/diff-snapshots.sh <kube-context>   # thin wrapper over diff -ru before/ after/
```

### 4.3 What each diff should show

| Dimension | Expected on TMC SM | Expected on a guest |
| --- | --- | --- |
| Repositories / packages | `tanzu-mission-control-packages` → 1.4.4; `tanzu-standard` → `v2026.1.21`; installed package versions bump accordingly | `tanzu-standard` → `v2026.1.21`; installed versions move only where a wide constraint allows |
| Node states | No node changes | TKR/kubelet may bump on a rolled guest; **no** node stuck `NotReady` |
| Workloads / images | TMC SM control-plane images on 1.4.4 tags; pods `Running` | TMC agent image bumped in `vmware-system-tmc`; Standard-package controller images (Flux, Contour, …) bumped where installed |
| Named components | cert-manager image tag per the v2026.1.21 catalog; velero (if DP-enabled) per 1.4.4 | cert-manager / Contour / fluxcd package **and** image tags move only where a wide constraint allows; velero image tag matches the 1.4.4-bundled version — **confirm against the v2026.1.21 / 1.4.4 release notes** |
| CRD & API surface | CRDs may add served versions; **no** APIService flips to `Available=False`; `api-resources.err` stays empty | Flux/Contour CRDs may bump served/storage versions; `api-resources.err` **must stay empty** — a `*.toolkit.fluxcd.io` entry there is the [§7](#7-the-continuous-delivery--flux-risk) break |
| Reconcile status | `pkgi-status` all `Reconcile succeeded` | Flux CRs `Ready=True` with an advancing `lastAppliedRevision`; pkgi succeeded |
| Webhooks | Unchanged | cert-manager webhook CA bundle may rotate; webhook count/names otherwise stable |
| Guest components | n/a unless installed | `HTTPProxy` objects stay `valid`; `Certificate` / `ClusterIssuer` stay `Ready` |

Anything outside this — a policy object that changed, a workload that vanished, a
node that won't go `Ready`, an APIService gone `Available=False` — is a
**finding**. Capture it before chasing the Flux-specific signals in
[§7](#7-the-continuous-delivery--flux-risk). (§3.2 is the narrower Flux/CRD
storage-version inventory; this snapshot is the broad state.)

---

## 5. Running the upgrade

The upgrade is driven by the **`tmc-sm` installer** — a 13-step workflow
(pre-check → relocate images → cert-manager → update package repository →
reconcile the `tmc` package → post-verify → resize). The **installer UI** and the
**`tmc-sm` CLI** are two front-ends over that _same_ engine; a third, lower-level
path (raw Carvel `tanzu package …`, [§5.2](#52-raw-carvel-inspection--troubleshooting-only))
is what the installer runs internally.

Whichever front-end you use, the upgrade does the same three things, in order:

1. Bump `tanzu-mission-control-packages` → 1.4.4 and reconcile the `tmc`
   PackageInstall (package `tmc.tanzu.vmware.com`) on the SM cluster.
2. Rewrite the `tanzu-standard` PackageRepository URL → `:v2026.1.21` on the SM
   cluster **and on every managed guest**.
3. Roll a newer TMC cluster-agent into each guest's `vmware-system-tmc`
   namespace.

Because the guest-side URL rewrite is TMC-owned, you **cannot** revert it by
editing the guest `PackageRepository` — TMC re-asserts it. The only knob you
control is what sits at that URL in Harbor (which is why [§3.1](#31-stage-the-tanzu-standard-bundle-into-harbor-do-this-first)
comes first).

### 5.1 UI vs CLI

| | Installer **UI** | `tmc-sm` **CLI** | Raw **Carvel** |
| --- | --- | --- | --- |
| What it is | Browser wizard over the installer | Same installer, headless, values-file driven | Poke the two Carvel objects directly |
| Pre-checks, image relocation, cert-manager, post-verify, resize | ✅ all 13 steps | ✅ identical | ❌ skips 5 of 13 |
| Repeatable / air-gap / change-control | ⚠️ manual clicks | ✅ scriptable, logged, versionable values | ✅ but no safety rails |
| Best for | first run, interactive validation | repeatable lab→prod, air-gapped, automation | inspection / troubleshooting |

Both front-ends need the 1.4.4 images staged in Harbor first
(`tmc-sm push-images`) and both consume the same `sm_values.yaml`. For a
lab→prod, air-gapped rollout the **CLI is the better default** — same engine as
the UI, but repeatable, logged (the run lands in a `tmc-*-upgrade.log`), and
diffable across environments; use the UI for interactive validation on a first
run.

- **UI:** launched via `tmc-sm console` (serves the browser wizard); see
  [Upgrading TMC Self-Managed — UI][tmc-upgrade-ui]. This is how this
  environment's 1.4.2 → 1.4.4 upgrade was actually run.
- **CLI (headless):**

  ```bash
  # 1. Stage the 1.4.4 bundle into Harbor (once); skipped on re-run if present
  tmc-sm push-images ...

  # 2. Run the installer headless against your values file. It is idempotent —
  #    with a prior install present it upgrades in place.
  # TODO: verify the exact headless subcommand/flags (`tmc-sm --help`) on the
  #       Linux jumpbox — tmc-sm is not supported on macOS. The line below is the
  #       inferred shape, NOT a confirmed command; this env was upgraded via
  #       `tmc-sm console` (UI), so the CLI form is unverified.
  tmc-sm install --config sm_values.yaml ...
  ```

### 5.2 Raw Carvel (inspection / troubleshooting only)

Steps 9–10 of the installer are, underneath:

```bash
tanzu package repository update tanzu-mission-control-packages \
  --url harbor.lab1.mmtm.ai/tmc-sm/package-repository:1.4.4 -n tmc-local
# wait for reconcile, then the platform PackageInstall reconciles to 1.4.4:
tanzu package installed update tmc --values-file sm_values.yaml -n tmc-local
```

Running these by hand skips 5 of the 13 installer steps (pre-checks, image
relocation, cert-manager, post-verify, resize), so reach for it to inspect or
unstick a reconcile — not as the primary upgrade path.

---

## 6. Verification

### 6.1 TMC SM cluster

- `tanzu package repository list -A` — `tanzu-mission-control-packages` on the
  1.4.4 tag; `tanzu-standard` on `v2026.1.21`.
- `tanzu package installed get tmc -n tmc-local` — version bumped to 1.4.4,
  status `Reconcile succeeded` (the platform package is `tmc.tanzu.vmware.com`,
  installed as `tmc` — not `tanzu-mission-control`).
- All TMC SM pods running on new images; no `ImagePullBackOff` /
  `CrashLoopBackOff`.
- UI loads, login works, About/version shows **1.4.4**.
- Contour/ingress on the SM cluster healthy.

### 6.2 Each managed guest

```bash
kubectl -n tkg-system get pkgr tanzu-standard -o yaml | grep -E 'image|Reconcile'
```

Expect `ReconcileSucceeded` and the `:v2026.1.21` URL. If you see
`ReconcileFailed` / `NOT_FOUND`, jump to
[§10](#10-troubleshooting-guest-tanzu-standard-reconcilefailed).

Also confirm:

- `tanzu tmc cluster list` (or UI) — every managed cluster still `HEALTHY`.
- TMC agent pods in `vmware-system-tmc` running on bumped image tags.
- Policies, TMC-managed secrets / secret-exports, CD enablement state, git
  repository credentials, and cluster-group/workspace memberships **unchanged**.
  Any drift here is a finding, not expected — capture it before chasing
  Flux-flavored noise.

### 6.3 Tip on interpreting a guest bundle bump

The Tanzu Standard bundle is a **catalog** — it ships many versions of every
package. A bundle bump does **not** force a version onto a cluster; the
cluster's `PackageInstall.spec.packageRef.versionSelection.constraints` decides
what kapp-controller reconciles to. A wide constraint (`>=0.0.0`, the TMC-managed
default) will uptake the new catalog max; a tight constraint holds the old
version. Check constraints before the upgrade, not after:

```bash
kubectl get packageinstall -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.packageRef.refName} @ {.spec.packageRef.versionSelection.constraints}{"\n"}{end}'
```

---

## 7. The Continuous Delivery / Flux risk

This is the single risk that can **silently** break a managed cluster. It stems
from one line in the TMC enable-CD docs:

> If Flux CRDs are present, TMC uses the currently installed instance rather than
> installing a new one. If the CRDs are not present, TMC installs the Flux source
> and Kustomize controllers and manages their lifecycles.

**Translation:** on any guest where the Tanzu Standard `fluxcd-*` packages
(`fluxcd-source-controller` / `fluxcd-kustomize-controller` /
`fluxcd-helm-controller`) are installed, **kapp-controller — not TMC — owns
Flux's lifecycle.** When the bundle bumps to v2026.1.21, kapp-controller
re-templates those PackageInstalls, rolling new controller images and possibly
changing the
`*.toolkit.fluxcd.io` CRD storage version. TMC CD-managed reconciliations then
start failing with:

```text
failed to get API group resources: unable to retrieve the complete list of
server APIs: helm.toolkit.fluxcd.io/v2
```

**The SM upgrade succeeds. The guest looks `HEALTHY` in TMC. CD silently stops
reconciling.**

### Decision tree per guest

```text
Is TMC CD enabled on this cluster?
  ├─ No  ─► Standard Repo bump is low-risk. Confirm Contour, done.
  └─ Yes ─► Is a `fluxcd-*` PackageInstall present (ns tanzu-fluxcd-packageinstalls)?
             ├─ No  ─► TMC owns Flux; the bump can't mutate it. Safe.
             └─ Yes ─► Dual-ownership. Pick one:
                 (a) Disable TMC CD before Phase B, re-enable after.
                     Brief CD outage; lowest risk. TMC re-owns Flux on re-enable.
                 (b) Co-resident: leave both, treat the first post-upgrade
                     reconcile as the canary (below). Halt on API-group errors.
                 (c) Remove the `fluxcd-*` PackageInstalls entirely (KB 375864).
                     Long-term clean, short-term churn.
```

### Post-upgrade canary (per CD-enabled guest)

```bash
flux reconcile source git <gr-name> -n <ns>
flux reconcile kustomization <ks-name> -n <ns>

kubectl -n <flux-ns> logs -l app=source-controller    --tail=200 -f
kubectl -n <flux-ns> logs -l app=kustomize-controller --tail=200 -f
kubectl -n <flux-ns> logs -l app=helm-controller      --tail=200 -f
```

**Halt criterion:** any `failed to get API group resources … *.toolkit.fluxcd.io`
error (KB 369984). No further work on the affected cluster until CD is restored.
Then diff the [§3.2](#32-inventory-every-cd-enabled-guest) inventory against
current state.

---

## 8. Contour on guest clusters

The other user-visible impact, far less prone to silent breakage than Flux. If
Contour is installed on a guest via the Standard `contour.tanzu.vmware.com`
package, v2026.1.21 reconciles it to a newer Contour/Envoy pair. Watch:

- **`HTTPProxy` schema** — additive in 1.x; older objects stay valid.
- **Envoy pod roll** — brief LB connection churn; use a maintenance window if
  the cluster fronts real traffic.
- **`LoadBalancer` Service IP retention** — the Service isn't touched, but
  double-check IPs if cloud-provider integration reconciled in the same window.
  (Open lab item: static Envoy LB IP allocation via NSX vs. current dynamic LB.)

If Contour was installed via TMC's extensions catalog rather than the Standard
`PackageInstall`, the bundle bump does not move it. Confirm which case you're in
with `tanzu package installed list -A`.

### 8.1 O'Reilly Automotive exception — pinned Contour 1.28

**This customer runs Contour self-managed.** Rather than take Contour from the
TMC add-on catalog, O'Reilly manually provisioned it as a Carvel
`PackageInstall` of the Tanzu Standard `contour.tanzu.vmware.com` package,
**pinned to `1.28.2+vmware.1-tkg.1`**, and wants to hold at Contour 1.28 for now.

**Verdict: the SM upgrade is safe for this install — _conditionally_.** Because
the install is a **tight-pinned** `PackageInstall`, the catalog-vs-constraint
model in [§6.3](#63-tip-on-interpreting-a-guest-bundle-bump) applies: a bundle
bump does **not** force a version onto a pinned install. This was verified in
lab1 — a guest with Contour pinned to an exact version stayed
`ReconcileSucceeded` with an **unchanged image digest** across the
`v2025.6.18 → v2026.1.21` bump. Tanzu Standard bundles are additive supersets, so
`v2026.1.21` is expected to still carry Contour 1.28.2 for a pinned install to
resolve against — but that presence is the one thing to confirm, not assume
(precondition 2 below).

> **Support caveat — 1.28 keeps running, but is _not supported_.** "Safe" above
> means the pin holds and Contour 1.28.2 keeps **reconciling and serving traffic**
> through the upgrade — it does **not** mean the version is supported. Broadcom
> does not support Contour 1.28 at this TKG/TMC level, so holding here is a
> deliberate, **unsupported configuration**: acceptable as a time-boxed choice,
> but O'Reilly should plan a move to a supported Contour version and expect an
> "upgrade to a supported version first" response on any Contour support case
> filed against 1.28. Confirm the current supported-version floor via Broadcom
> support: [Broadcom support portal][broadcom-support].

Two preconditions **must be verified before Phase B** — do not assume:

1. **The constraint is pinned to the exact 1.28.2 version, not wide.** A wide
   constraint (`>=0.0.0`) would uptake the catalog max (currently up to
   1.32.0+) and move them _off_ 1.28 — the opposite of what they want.

   ```bash
   kubectl get pkgi -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.packageRef.refName} @ {.spec.packageRef.versionSelection.constraints}{"\n"}{end}' \
     | grep -i contour
   # expect: ... contour.tanzu.vmware.com @ 1.28.2+vmware.1-tkg.1   (exact, not >=0.0.0)
   ```

2. **`contour.tanzu.vmware.com.1.28.2+vmware.1-tkg.1` is present in the
   `v2026.1.21` catalog.** It is in `v2025.6.18` and Tanzu Standard catalogs are
   additive, so it is expected to persist — but confirm against the **staged
   `v2026.1.21` bundle** (query on a cluster already on `v2026.1.21`, or inspect
   the staged bundle). If it is absent, the pinned install flips
   `ReconcileFailed` / `NOT_FOUND` — the same failure shape as
   [§10](#10-troubleshooting-guest-tanzu-standard-reconcilefailed).

   ```bash
   kubectl get packages -A | grep -i contour | grep '1.28.2+vmware.1-tkg.1'
   ```

**Post-upgrade:** confirm the Contour `PackageInstall` still
`ReconcileSucceeded` on `1.28.2+vmware.1-tkg.1` with an **unchanged** controller
image tag — no roll means the pin held and Envoy did not churn.

---

## 9. Velero / Data Protection

Velero is the third guest-side component with a lifecycle of its own — but unlike
Flux ([§7](#7-the-continuous-delivery--flux-risk)) and Contour
([§8](#8-contour-on-guest-clusters)), it does **not** ride the Tanzu Standard
bundle at all. TMC **Data Protection** deploys and reconciles Velero through the
**TMC cluster agent** (`vmware-system-tmc`), and its version is **pinned to the
TMC SM release** — there is no `PackageInstall`, no kapp `App`, and no
`tanzu-standard` entry to read it from. The `v2026.1.21` bump therefore cannot
move it (which is also why the [§4](#4-state-checkpoints-before-and-after)
matrix tracks Velero by image tag only).

**Current state (TMC SM 1.4.4), verified on the DP-enabled guest:**

| Component | Version | Source |
| --- | --- | --- |
| Velero (server + node-agent) | **v1.13.2** | bundled with TMC SM 1.4.4 |
| velero-plugin-for-aws | v1.9.2 | DP images |
| velero-plugin-for-microsoft-azure | v1.9.2 | DP images |
| velero-plugin-for-csi | v0.7.1 | DP images |

Images come from `…/extensions/data-protection-images/…`, not
`…/packages/standard/repo`. **Expectation: the 1.4.2 → 1.4.4 upgrade leaves
Velero at 1.13.2.** Staying on 1.13.2 after the upgrade is correct, not a
regression — Data Protection did not (and cannot) jump Velero to 1.15 on its own.

**Verify:**

```bash
kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n velero exec deploy/velero -c velero -- /velero version --client-only   # Version: v1.13.2
kubectl get pkgi -A | grep -i velero   # expect: none — Velero is agent-managed, not a package
```

### 9.1 Upgrading Velero (e.g. 1.13 → 1.15)

**You cannot upgrade the TMC-managed Velero in place, and should not try.**

- **The agent owns it.** Hand-patching the `velero` deployment image is reverted
  by the Data Protection controller (drift correction), and leaves you
  unsupported in the meantime.
- **1.13 → 1.15 is not an image swap.** Velero 1.14/1.15 carry CRD/API and
  plugin-compatibility changes; the bundled plugins here (`aws` 1.9.2, `csi`
  0.7.1) are matched to 1.13. A manual bump risks breaking BSLs, schedules, and
  existing backup/restore compatibility.

**Supported path — upgrade TMC.** Velero version is a function of the TMC SM
release, so move Velero forward by upgrading TMC SM to a release whose Data
Protection bundles the target Velero. Confirm the exact TMC → Velero mapping in
the **Data Protection component matrix** of the target release notes (1.4.4 →
1.13.2; a later line carries newer Velero). The new Velero + plugin images then
roll into each DP-enabled guest's `velero` namespace the same agent-driven way
the rest of this runbook describes.

**Only alternative:** disable TMC Data Protection and run a **standalone**
upstream Velero yourself. That gets you any Velero version immediately but you
lose TMC-integrated backup management (policies, schedules, and the TMC UI). It
is a decoupling decision, not an upgrade — not recommended just to advance one
minor version.

> **Broadcom support (portal).** Support-portal query confirming the supported
> Velero version for TMC 1.4.4 and whether/how a newer Velero can be run:
> [TMC 1.4.4 — supported Velero version & upgrade path][broadcom-support].

---

## 10. Troubleshooting: guest `tanzu-standard` ReconcileFailed

**Symptom (seen in lab1, 2026-06-15):** after the SM upgrade, a guest's
`tanzu-standard` PackageRepository is `ReconcileFailed` with:

```text
NOT_FOUND: artifact .../packages/standard/repo:v2026.1.21 not found
```

**Cause:** TMC rewrote the guest's bundle URL to `:v2026.1.21`, but that bundle
was never staged in Harbor. (This is why [§3.1](#31-stage-the-tanzu-standard-bundle-into-harbor-do-this-first)
must happen _before_ the upgrade.)

**First confirm the failure mode** — `NOT_FOUND` / `404` means the bundle is
missing (fixed by staging it). `unauthorized` / `denied` or `x509` are Harbor
credential/cert problems and are **not** fixed by copying the bundle:

```bash
kubectl -n tkg-system describe pkgr tanzu-standard
kubectl -n tkg-system get pkgr tanzu-standard -o yaml   # see .status.usefulErrorMessage
```

**Fix:** stage the bundle per [§3.1](#31-stage-the-tanzu-standard-bundle-into-harbor-do-this-first),
then kick a reconcile:

```bash
kubectl -n tkg-system annotate pkgr tanzu-standard kctrl.carvel.dev/paused=true  --overwrite
kubectl -n tkg-system annotate pkgr tanzu-standard kctrl.carvel.dev/paused-       --overwrite
kubectl -n tkg-system get pkgr tanzu-standard -w
```

End state: `ReconcileSucceeded`, `.status.usefulErrorMessage` cleared.

**Scope:** one push to Harbor serves _all_ guests (they share the URL TMC
stamps). Each remaining guest just needs the pause/unpause kick, or picks it up
on the next poll interval — no per-guest re-copy.

---

## 11. Companion documents & references

### In this repo

- **`upgrade-impacts.md`** — deeper treatment of guest-cluster impacts, the
  catalog-vs-constraint model, per-cluster runbook, and Harbor repository
  modeling (Options A/B/C for laying out the bundle paths legibly).
- **`tmc-upgrade-considerations.md`** — raw session transcript with the lab1
  reproduction, the validated `imgpkg copy` recipe, and the resolution log; also
  the fresh-install CA-material prep for `serverTLS.clusterIssuer.caSecret`.
- `tmp/` — working artifacts: 1.4.4 upgrade log, `sm_values.yaml`, agent
  configs, worksession notes.

### External

- [Upgrading TMC Self-Managed — UI flow][tmc-upgrade-ui]
- [TMC SM 1.4 documentation root](https://techdocs.broadcom.com/us/en/vmware-tanzu/standalone-components/tanzu-mission-control-self-managed/1-4/tmc-self-managed-documentation.html)
- [Enable Continuous Delivery for a cluster or cluster-group](https://techdocs.broadcom.com/us/en/vmware-tanzu/standalone-components/tanzu-mission-control-self-managed/1-4/tmc-self-managed-documentation/using-tmc/managing-cluster-resources-with-continuous-delivery/enable-continuous-delivery-for-a-cluster-or-cluster-group.html)
- [Carvel kapp-controller `PackageRepository` reference](https://carvel.dev/kapp-controller/docs/develop/packaging/)
- [`imgpkg copy`](https://carvel.dev/imgpkg/docs/develop/copy/) · [air-gapped relocation](https://carvel.dev/imgpkg/docs/develop/air-gapped-workflow/)
- [Flux upgrade compatibility](https://fluxcd.io/flux/installation/upgrade/) · [Flux components/CRDs](https://fluxcd.io/flux/components/)
- [Broadcom support — TMC 1.4.4 supported Velero version & upgrade path][broadcom-support] (portal search; see [§9](#9-velero--data-protection))
- KB 369984 — CD enablement API-group resolution error
- KB 375864 — removing the Flux CD package after disable

[tmc-upgrade-ui]: https://techdocs.broadcom.com/us/en/vmware-tanzu/standalone-components/tanzu-mission-control-self-managed/1-4/tmc-self-managed-documentation/install-and-run-tmc-self-managed/upgrading-tmc-self-managed.html#upgrade-tmc-ui
[broadcom-support]: https://support.broadcom.com/web/ecx/search?searchString=I%20am%20running%20TMC%201.4.4.%20%20What%20is%20the%20supported%20version%20of%20Velero%20used%20by%20Data%20Protection,%20is%20it%20possible%20to%20run%20Velero%201.5.x,%20and%20if%20so,%20how%20to%20do%20it.&from=0&sortby=_score&orderBy=desc&pageNo=1&aggregations=%255B%257B%2522type%2522:%2522productname%2522,%2522filter%2522:%255B%2522Advanced%2520Cyber%2520Compliance%2522,%2522VCF%2520Automation%2522,%2522VCF%2520Operations%2522,%2522VCF%2520Operations%2520for%2520Networks%2522,%2522VCF%2520Private%2520AI%2520Services%2522,%2522VMware%2520Cloud%2520Director%2522,%2522VMware%2520Cloud%2520Foundation%2522,%2522VMware%2520Cloud%2520Foundation%2520Edge%2522,%2522VMware%2520Data%2520Services%2520Manager%2522,%2522VMware%2520Data%2520Services%2520Manager%2520for%2520VCF%2520Private%2520AI%2520Services%2522,%2522VMware%2520HCX%2522,%2522VMware%2520Live%2520Recovery%2522,%2522VMware%2520NSX%2522,%2522VMware%2520SDDC%2520Manager%2520/%2520VCF%2520Installer%2522,%2522VMware%2520Site%2520Recovery%2520Manager%2522,%2522VMware%2520vCenter%2520Server%2522,%2522VMware%2520vDefend%2520Firewall%2522,%2522VMware%2520vDefend%2520Firewall%2520with%2520Advanced%2520Threat%2520Prevention%2522,%2522VMware%2520vSAN%2522,%2522VMware%2520vSphere%2520ESXi%2522,%2522VMware%2520vSphere%2520Foundation%2522,%2522VMware%2520vSphere%2520Kubernetes%2520Service%2522%255D%257D%255D&uid=25b4c588-e69f-11ea-beba-0242ac12000b&resultsPerPage=10&exactPhrase=&withOneOrMore=&withoutTheWords=&pageSize=10&language=en

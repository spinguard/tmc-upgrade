# VKS 3.7.0 Misconfiguration Pre-Check — High-Level Assessment

**Date:** 2026-09-17 · **Environment:** lab1 · **Author:** Bill Kable

## Summary

We set out to reproduce, on VKS 3.7.0, the known scenario in which Gatekeeper blocks a VKr upgrade
of a TMC-managed guest cluster. **It did not reproduce.** The upgrade ran to completion through TMC
with Gatekeeper installed and active — no bypass annotation, no unmanage/re-register, no Cluster API
intervention.

That outcome is not evidence the problem is fixed. Once the mechanism was traced, the more useful
conclusion is that the pre-check is a **name-matching heuristic rather than a risk assessment**, and
that TMC's own Gatekeeper deployment happens to sit on the allowlist while a customer's would not.

**Environment note:** the lab runs VKS **3.7.0** (`vks-addons-3.7.0-20260723`, ClusterClass
`builtin-generic-v3.7.0`, supporting VKr 1.33–1.36). The original objective referenced 3.7.1; the
results below are 3.7.0 and should not be assumed to carry forward without re-testing.

## What was tested

A TMC custom policy (`tmc-require-labels`, `enforcementAction: dryrun`) was applied to a TMC-managed
guest cluster to trigger TMC's `gatekeeper-operator`, which installs Gatekeeper and registers its
admission webhooks. The cluster was then upgraded VKr `1.35.6 → 1.36.2`.

The upgrade target sat below the ClusterClass ceiling, so the separate clusterclass-ceiling
impediment was deliberately kept out of the picture and the pre-check behaviour could be observed in
isolation.

## What we found

### 1. A different sub-check fires first, and hides the one you are looking for

`SystemChecksSucceeded` aggregates several sub-checks but **reports only one failure message at a
time**. On a single-worker cluster, TMC's Gatekeeper (three replicas, `minAvailable: 1`, only
*preferred* anti-affinity) trips the PodDisruptionBudget sub-check, which then masks the webhook
sub-check entirely.

The practical hazard is diagnostic: an operator seeing only a PDB message may reasonably conclude
the webhook check passed. It had not been evaluated in the message at all. Adding a second worker
cleared it — and notably the check passed as soon as a second node merely *existed*, before the
replicas had actually redistributed, indicating it models whether a drain *could* succeed rather
than inspecting current placement.

### 2. The webhook check matches on name, and ignores whether the webhook is actually dangerous

Controlled single-factor probes — a dummy webhook registered while one property at a time was
varied — produced a consistent picture:

| Factor varied | Effect on the check |
|---|---|
| Webhook name: invented vendor | not flagged |
| Webhook name: a documented vendor | **flagged, within ~3 seconds** |
| `failurePolicy` — `Ignore` vs `Fail` | none |
| `namespaceSelector` — absent, or excluding system namespaces | none |
| Backing service — live vs. nonexistent | none |
| Vendor/management annotations | none |

The check matches the webhook's **name** against a vendor list (per the 3.7 release notes:
Gatekeeper, Kyverno, Rancher, k8tz, Dynatrace, Linkerd, OpenTelemetry). Every property that governs
whether a webhook can *actually* stall an upgrade is ignored.

This cuts both ways:

- **False positives.** A webhook that cannot block anything — `failurePolicy: Ignore`, a dead
  backend, no matching resources — is still flagged and still blocks the upgrade.
- **False negatives.** A genuinely hazardous configuration passes if its name is not on the list.

### 3. TMC's Gatekeeper is already allowlisted; a customer's would not be

With a dummy webhook named `validation.gatekeeper.sh` registered under a *different*
ValidatingWebhookConfiguration, the failure message read "**1 webhook was detected**" — counting
only the dummy, while TMC's identically-named webhook went uncounted. TMC's install is therefore
already on the cluster's allowlist, and the allowlist keys on something narrower than the webhook
name — most likely the ValidatingWebhookConfiguration object name. *(Inference from observed
counting behaviour, not from documentation.)*

This is why the scenario did not reproduce. It also means **the impediment is narrowed, not
removed**: it still applies to customer-deployed Gatekeeper under a different object name, and to
every other vendor on the list.

## Assessment

**The pre-check behaves as a compatibility blocklist, not a safety analysis.** It answers "is a
known third-party admission webhook present?" rather than "would this configuration stall an
upgrade?" That is a defensible design for a conservative gate, but it should be described that way,
because the two questions diverge sharply in practice.

**The most striking case of that divergence is favourable to TMC and worth flagging.** TMC's
Gatekeeper exempts only three namespaces (`gatekeeper-system`, `kube-system`, `vmware-system-tmc`).
`vmware-system-antrea`, `vmware-system-csi` and `tkg-system` are **not** exempt — precisely the
namespaces Broadcom's own KB 323447 identifies in the Gatekeeper upgrade-deadlock scenario. We
confirmed that even with `failurePolicy: Fail` on Pods, this configuration passes the check, because
it is allowlisted. So a TMC-managed cluster can be admitted for upgrade in a state that Broadcom
documents elsewhere as capable of deadlocking. We did not observe a deadlock, and the upgrade
succeeded — but the gate did not evaluate the risk either way.

**For customers the operational picture is unchanged where it matters.** Anyone running their own
Gatekeeper, Kyverno, Rancher or the other listed vendors will still hit the block, and the TMC
reconcile conflict — TMC reverting the manifest changes needed to bypass it — still forces the
unmanage/patch/re-register workaround.

## Open questions

1. **The allowlist annotation key is undocumented.** The 3.7 release notes confirm the feature and
   the failure message references "Cluster's allowlist", but the key appears in neither the release
   notes nor the override techdoc, is absent from the Cluster CRD schema and the ClusterClass
   variables, and is not present on a working cluster. It needs GSS or Supervisor control-plane node
   access.
2. **Does TMC reconcile the allowlist annotation out?** This is the question that decides whether
   the feature helps TMC-managed clusters at all. If TMC strips it as it strips the blanket bypass
   annotation, the allowlist is no improvement for this audience and the impediment stands in full.
3. **What changed between 3.6.x and 3.7.0?** The earlier 3.6.3 observation flagged
   `validation.gatekeeper.sh` directly. Whether 3.7.0 added the default allowlist entry, or the
   detection logic changed, is not established.
4. **Does 3.7.1 behave the same?** All results here are 3.7.0.

## Recommended next steps

1. Obtain the allowlist annotation key from GSS, then test whether TMC reconciles it out.
2. Raise the false-positive/false-negative characteristic with product management — specifically
   that `failurePolicy`, `namespaceSelector` and backend health are not considered.
3. Raise the PDB masking behaviour as a diagnosability issue: surfacing only one sub-check failure
   at a time actively misleads operators.
4. Re-test on 3.7.1 before making any version-specific claim to customers.

# TMC Self-Managed 1.4.5 — public `landing` endpoint moved to the internal CA by a template change

**Summary:** Between 1.4.4 and 1.4.5 a single line of the `landing-service` certificate template
was changed from `externalIssuerRef` to `internalIssuerRef`. `externalIssuerRef` is where the
operator's `serverTLS.clusterIssuer` value is wired in; `internalIssuerRef` is a chart default
(`kind: Issuer, name: dev`) that TMC Self-Managed does not expose. The effect is that
`landing.tmc.<domain>` — a browser-facing hostname, and the first hop of the login flow — is now
served a certificate chained to TMC's internal, install-time-generated service CA
(`CN=Olympus Development CA`) instead of the operator-supplied CA.

The hostname, the Ingress, and the load balancer are unchanged. Only the signature underneath
changed, to one no browser has reason to trust. Because TMC's Envoy also sends HSTS on this
host, the resulting error is **not click-through bypassable**, so the console becomes
unreachable on upgrade with no browser-side recovery. No `sm_values.yaml` setting corrects it.

**The fix is a one-token revert: restore `externalIssuerRef` for `landing-service-server-tls`,
as in 1.4.4.**

| Field | Value |
|---|---|
| Regression introduced in | 1.4.5 (upgraded from 1.4.4 on 2026-08-26 23:31 UTC) |
| Component | `landing-service` |
| Component revision | `d1146d7e…` (1.4.4) → `e36db45d2e43e9f0d9c376cec0c1ef5ec0bf7166` (1.4.5) |
| Template | `upstream/templates/global-services/025-certificate-landing-service-server-tls.yaml` |
| Component contact | `olympus-jigglypuff@vmware-csp.pagerduty.com` |
| Affected hostname | `landing.tmc.lab1.mmtm.ai` |
| Changed | 2026-08-26 23:32:33 UTC |
| Observed | 2026-08-27 UTC |

---

## Root cause

Both the `1.4.4` and `1.4.5` package-repository bundles were still present in the local registry,
so the templates could be pulled and diffed directly.

`upstream/templates/global-services/025-certificate-landing-service-server-tls.yaml`:

```diff
- issuerRef: {{ .Values.externalIssuerRef | toYaml | nindent 4 }}
+ issuerRef: {{ .Values.internalIssuerRef | toYaml | nindent 4 }}
```

The two values are defined identically in `upstream/values.yaml` in **both** releases, so the
values did not move — only the reference to them did:

```yaml
internalIssuerRef:  {kind: Issuer,        name: dev}
externalIssuerRef:  {kind: ClusterIssuer, name: letsencrypt-prod}   # overridden by TMC SM
```

`externalIssuerRef.name` is exactly where the operator's setting is injected, in
`config/secrets/tmc-local-stack-values.yaml:135` of the outer bundle:

```yaml
externalIssuerRef:
  name:  #@ tls_values.clusterIssuer     # <- serverTLS.clusterIssuer from sm_values.yaml
```

`serverTLS.clusterIssuer` is therefore still wired correctly and still honored everywhere else.
The landing template simply stopped reading it. Because `internalIssuerRef` is a chart default
that TMC Self-Managed never surfaces in `sm_values.yaml`, there is no supported configuration
that corrects this.

The Ingress in front of the certificate is byte-identical between the two releases apart from its
revision annotation, and still consumes `secretName: landing-service-tls`:

```
$ diff stack144/…/044-ingress-landing-service-ingress-global.yaml \
       stack145/…/044-ingress-landing-service-ingress-global.yaml
7c7
<     olympus.eng.vmware.com/component.revision: d1146d7efa6b1f721bcd7052d9b2b4901680af54
---
>     olympus.eng.vmware.com/component.revision: e36db45d2e43e9f0d9c376cec0c1ef5ec0bf7166
```

### Scope of the template change

In 1.4.4, four certificate templates consumed `externalIssuerRef`. In 1.4.5, two do:

| Template | 1.4.4 | 1.4.5 |
|---|---|---|
| `024-certificate-auth-manager-server-tls` | external | external |
| `222-certificate-stack-tls` | external | external |
| `025-certificate-landing-service-server-tls` | external | **internal** |
| `026-certificate-tenancy-service-server-tls` | external | **internal** |

`tenancy-service` moved too, but has no public Ingress, so the change is invisible there. That
contrast is the point: moving a certificate to the internal CA is only damaging where the
hostname is browser-facing. `landing` is the one that is.

### The BYO-certificate guard was also dropped

In 1.4.4 the landing Certificate was wrapped in `{{- if not .Values.certificateImport }}`, so
operators supplying their own certificates got no generated Certificate at all. In 1.4.5 that
wrapper is gone, while the sibling `auth-manager` template kept its:

| Template | 1.4.4 | 1.4.5 |
|---|---|---|
| `024-certificate-auth-manager-server-tls` | guarded | guarded |
| `025-certificate-landing-service-server-tls` | **guarded** | **no guard** |

This widens the blast radius beyond self-signed deployments: a `certificateImport` deployment now
has an internal-CA certificate created over the top of the operator's own.

### Version timeline

The Package objects date the upgrade precisely. Twelve third-party packages retain their original
install timestamps; the four TMC packages were recreated:

```
2026-08-21T13:23:15Z  (x12)       contour, kafka, redis, minio, pinniped, cert-manager, …
2026-08-26T23:31:43Z  1.4.5       tmc.tanzu.vmware.com.1.4.5
2026-08-26T23:31:55Z  0.1.8751591 tmc-local-stack-secrets, tmc-local-support
2026-08-26T23:31:56Z  0.1.8751591 tmc-local-stack
```

A new `creationTimestamp` on a name that embeds the version means the object did not previously
exist — the deployment was on 1.4.4 (stack `0.1.3839058`) until 23:31:43, and the landing
certificate was reissued fifty seconds later at 23:32:33.

---

## Plain-language summary

TMC uses two private certificate authorities. One is **external** — the operator supplies it, and
it signs the handful of hostnames a person types into a browser. The other is **internal** — TMC
generates it at install time so its own services can authenticate to each other inside the
cluster. Only the external CA ever needs to be trusted by a browser; the internal one is not
meant to leave the cluster.

`landing.tmc.<domain>` is a browser hostname. It is the first page of the login flow.

In 1.4.4 its certificate was signed by the external CA, so any browser trusting the operator's CA
could reach it. In 1.4.5 one line of the template was changed to sign it with the internal CA
instead. The web address is the same and the load balancer is the same — only the signature
changed, to one that no browser has any reason to trust.

The result is that the TMC console becomes unreachable on upgrade, and because TMC also sends
HSTS on that hostname, the browser refuses to offer the usual "proceed anyway" bypass. There is
no setting that corrects it: the internal issuer is a chart default that TMC Self-Managed does
not expose.

---

## Impact

The TMC console is unreachable. `landing` is the first hop of the login flow
(`/landing?subdomain=…` → 307 → `auth.…/api/v1/login`), so a hard TLS failure there blocks all
browser access to TMC even though every other endpoint in the stack is healthy and correctly
certified.

The failure is not recoverable from the browser. TMC's Envoy sends
`strict-transport-security: max-age=31536000; includeSubDomains; preload` on this host, and
Chrome had already cached that policy from earlier successful visits. With HSTS in force Chrome
removes the "Proceed anyway" interstitial entirely and returns a terminal
`net::ERR_CERT_AUTHORITY_INVALID`. An operator who has not separately trusted the internal
development CA has no way through, and the `includeSubDomains` directive published by
`tmc.lab1.mmtm.ai` re-asserts the policy over `landing` even if the operator deletes the
`landing` entry by hand.

The change is also self-reverting: kapp-controller reconciles the package roughly every ten
minutes and re-applies `issuerRef: dev`, so a manual correction to the `Certificate` does not
survive without pausing the `PackageInstall`.

---

## Environment

| Component | Version | Note |
|---|---|---|
| TMC Self-Managed | 1.4.5 | `PackageInstall/tanzu-mission-control`, constraint `1.4.5`, generation 12 |
| Contour | 19.3.2 | `contour.bitnami.com`, Envoy fronting all TMC hostnames |
| cert-manager | 1.12.10+vmware.1-tkg.1 | `cert-manager-tmcsm` |
| TMC cluster | `tmc` context | Supervisor 192.168.204.196, namespace `tmc-local` |
| Envoy LB VIP | 192.168.204.220 | `contourEnvoy.loadBalancerIP` |
| Client | macOS 26.5.2 (25F84) | Chrome 151.0.7922.175; `TMC Self-Managed CA` trusted in System keychain |

Relevant `sm_values.yaml`:

```yaml
serverTLS:
  type: clusterIssuer
  clusterIssuer:
    existing: false
    name: local-issuer
    namespace: cert-manager
```

---

## Evidence

### E1 — The public endpoint serves a certificate from an internal development CA

```
$ echo | openssl s_client -connect landing.tmc.lab1.mmtm.ai:443 \
    -servername landing.tmc.lab1.mmtm.ai 2>/dev/null | openssl x509 -noout -subject -issuer -serial -dates
subject=CN=landing.tmc.lab1.mmtm.ai
issuer=CN=Olympus Development CA
serial=937CF9CA85E724C5A595AF7537055BA9
notBefore=Aug 26 23:32:34 2026 GMT
notAfter=Aug 27 19:32:34 2027 GMT

Verify return code: 21 (unable to verify the first certificate)
```

Only the leaf is presented — no intermediate, no chain to anything an operator could pin.

### E2 — Every other externally-reachable hostname is correctly issued

```
$ for h in tmc auth; do openssl s_client -connect $h.tmc.lab1.mmtm.ai:443 ... ; done
subject=CN=tmc.lab1.mmtm.ai        issuer=CN=TMC Self-Managed CA   notBefore=Aug 21 13:40:49 2026 GMT
subject=CN=auth.tmc.lab1.mmtm.ai   issuer=CN=TMC Self-Managed CA   notBefore=Aug 21 13:40:21 2026 GMT
```

`TMC Self-Managed CA` is the CA minted from `serverTLS.clusterIssuer`, and it is present and
trusted in the client's System keychain. `Olympus Development CA` is not, and never has been —
it is not published to the operator anywhere.

Evaluated against the real macOS trust store rather than a keychain listing, the split is
unambiguous:

```
$ security verify-cert -c leaf-tmc.pem -p ssl -s tmc.lab1.mmtm.ai
...certificate verification successful.

$ security verify-cert -c leaf-landing.pem -p ssl -s landing.tmc.lab1.mmtm.ai
Cert Verify Result: CSSMERR_TP_NOT_TRUSTED
```

Same client, same trust store, same moment — the console hostname validates and the landing
hostname does not.

### E3 — The issuer was flipped, and only for this certificate

`CertificateRequest` history is the authoritative record of what changed:

```
$ kubectl -n tmc-local get certificaterequest
NAME                                ISSUER                       CREATED                REVISION
landing-service-server-tls-94xtx    ClusterIssuer/local-issuer   2026-08-21T13:40:19Z   1
landing-service-server-tls-q7bbp    Issuer/dev                   2026-08-26T23:32:33Z   2
stack-tls-qmh78                     ClusterIssuer/local-issuer   2026-08-21T13:40:48Z   1
agent-gateway-instack-tls-tzf7n     Issuer/dev                   2026-08-21T13:40:20Z   1
agent-gateway-instack-tls-fw7rt     Issuer/dev                   2026-08-26T23:32:30Z   2
api-gateway-instack-tls-ssh9d       Issuer/dev                   2026-08-21T13:40:51Z   1
api-gateway-instack-tls-sqq25       Issuer/dev                   2026-08-26T23:32:30Z   2
```

At install (Aug 21) `landing-service-server-tls` was issued by `local-issuer` — the correct,
operator-trusted CA. At 23:32:33 UTC on Aug 26 it was reissued by `dev`.

The same reconcile reissued `agent-gateway-instack-tls` and `api-gateway-instack-tls` three
seconds earlier, but those were already on `dev` at revision 1 and stayed there. **`landing` is
the only certificate in the deployment whose issuer actually changed.** It is also the only one
of the three that is publicly ingressed.

```
$ kubectl -n tmc-local get certificate <name> -o jsonpath='gen={.metadata.generation} rev={.status.revision}'
landing-service-server-tls          gen=2 rev=2      <-- issuer changed
agent-gateway-instack-tls           gen=2 rev=2      <-- reissued, issuer unchanged
api-gateway-instack-tls             gen=2 rev=2      <-- reissued, issuer unchanged
stack-tls                           gen=1 rev=1      <-- untouched
auth-manager-server-tls             gen=1 rev=1      <-- untouched
```

### E4 — This is the package template, not configuration drift

The `kapp.k14s.io/original` annotation records the manifest kapp-controller rendered and applied.
For `landing-service-server-tls` it contains, verbatim:

```json
"spec": {
  "commonName": "landing.tmc.lab1.mmtm.ai",
  "dnsNames": ["landing-service","landing-service-server","landing-service-metrics",
               "landing-service-rest","landing-service-server.tmc.lab1.mmtm.ai",
               "landing.tmc.lab1.mmtm.ai"],
  "duration": "8780h",
  "issuerRef": {"kind":"Issuer","name":"dev"},
  "renewBefore": "780h",
  "secretName": "landing-service-tls"
}
```

For `stack-tls`, the same annotation contains:

```json
"issuerRef": {"kind":"ClusterIssuer","name":"local-issuer"}
```

The desired state that TMC itself is publishing names `dev` for a certificate whose
`commonName` is a public hostname. Nothing in the cluster was hand-edited.

### E5 — The public Ingress terminates TLS with that exact secret

```
$ kubectl -n tmc-local get ingress landing-service-ingress-global -o jsonpath='{.spec.tls}'
[{"hosts":["landing.tmc.lab1.mmtm.ai"],"secretName":"landing-service-tls"}]
```

```
$ kubectl -n tmc-local get secret landing-service-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -serial -issuer
serial=937CF9CA85E724C5A595AF7537055BA9
issuer=CN=Olympus Development CA
```

The serial matches the certificate served on the wire in E1 exactly. There is no separate
public-facing certificate for this hostname anywhere in the namespace.

The same secret is simultaneously the component's **internal** service certificate — its SANs
carry `landing-service`, `landing-service-server`, `landing-service-metrics` and
`landing-service-rest` alongside the public FQDN. One secret is being asked to serve both an
internal mTLS identity and a browser-facing endpoint, which is what makes the issuer choice
ambiguous in the template.

### E6 — Only four certificates honor the operator-supplied issuer

```
$ kubectl -n tmc-local get certificate -o custom-columns=...
auth-manager-server-tls           ClusterIssuer/local-issuer   secret=server-tls
minio-tls                         ClusterIssuer/local-issuer   secret=minio-tls
pinniped-supervisor-server-tls    ClusterIssuer/local-issuer   secret=pinniped-supervisor-server-tls
stack-tls                         ClusterIssuer/local-issuer   secret=stack-tls
dev-ca                            Issuer/dev-root              secret=dev-ca-key

dev-issued: 46 of 51
```

Four certificates use `local-issuer`; 46 use `dev`. That split is coherent — external
hostnames on the operator CA, internal service identities on the development CA — and
`landing` is the single hostname that sits on the wrong side of it.

### E7 — HSTS makes the error terminal rather than click-through

```
$ curl -skD- -o /dev/null 'https://landing.tmc.lab1.mmtm.ai/landing?subdomain=tmc.lab1.mmtm.ai'
HTTP/2 307
location: https://auth.tmc.lab1.mmtm.ai/api/v1/login?state=...
server: envoy
strict-transport-security: max-age=31536000; includeSubDomains; preload
```

Chrome's cached policy (profile `Profile 8`, `TransportSecurity`):

```
landing.tmc.lab1.mmtm.ai   mode=force-https  include_subdomains=True  expiry=2027-08-26T08:57:15
tmc.lab1.mmtm.ai           mode=force-https  include_subdomains=True  expiry=2027-08-26T21:19:30
auth.tmc.lab1.mmtm.ai      mode=force-https  include_subdomains=True  expiry=2027-08-27T09:10:18
```

Chrome reports:

> You cannot visit landing.tmc.lab1.mmtm.ai right now because the website uses HSTS.

Note that `tmc.lab1.mmtm.ai` publishes `includeSubDomains`, so the policy covers `landing`
independently of `landing`'s own entry. Deleting one entry does not restore the interstitial
bypass, and visiting the console re-asserts the parent policy immediately.

### E8 — The endpoint demonstrably worked before the reissue

HSTS state is only recorded on a connection with no certificate error (RFC 6797 §8.1). The
cached `landing` entry expires `2027-08-26T08:57:15` local, i.e. it was written at
**2026-08-26 08:57 CDT (13:57 UTC)** — nine and a half hours *before* the 23:32:33 UTC reissue.
The browser could not have recorded that entry unless `landing` was serving a trusted chain at
that moment, which is consistent with revision 1 having been signed by `local-issuer` (E3).

### E9 — The change is re-applied automatically

```
$ kubectl -n tmc-local get app tmc-local-stack -o jsonpath='{.status.consecutiveReconcileSuccesses}'
89
$ kubectl -n tmc-local get app tmc-local-stack -o jsonpath='{.status.deploy.updatedAt}'
2026-08-27T14:14:56Z
```

All 16 `tmc-local` apps report `Reconcile succeeded` within the last ten minutes. Patching
`issuerRef` back to `local-issuer` without pausing `PackageInstall/tanzu-mission-control` is
reverted on the next reconcile.

---

## Ruled out

- **Compromise or MITM.** The full chain of custody is inside the cluster. The signing CA is
  `Certificate/dev-ca` → `secret/dev-ca-key` → `Issuer/dev` in `tmc-local`; its Subject Key
  Identifier `1B:E0:49:F5:2F:69:01:25:54:F5:36:00:DD:4C:4E:33:F8:92:5F:46` matches the
  Authority Key Identifier on the leaf served in E1. The requestor recorded on the
  `CertificateRequest` is `system:serviceaccount:cert-manager:cert-manager`. The serial on the
  wire matches the in-cluster secret byte for byte (E5). No external CA, key, or endpoint is
  involved.
- **A "development certificate" shipped in the release.** Nothing is shipped. `Issuer/dev-root`
  is `{"selfSigned":{}}` and `Certificate/dev-ca` (`isCA: true`, `duration: 87600h`) is minted by
  cert-manager at install time — the CA's `notBefore` (`Aug 21 13:38:44 2026 GMT`) equals the
  `creationTimestamp` of `secret/dev-ca-key` to the second. The key is generated in-cluster,
  unique to this deployment, and has never left it. "Development" is a naming artifact of the
  Olympus source tree; the CA is TMC's internal service-mesh root, and 46 of 51 certificates
  using it is correct design. The defect is one browser-facing hostname crossing that boundary,
  not the existence of the internal CA.
- **Expired certificate.** `notAfter=Aug 27 19:32:34 2027`; the error is
  `ERR_CERT_AUTHORITY_INVALID`, not a date failure.
- **Hostname mismatch.** `landing.tmc.lab1.mmtm.ai` is present in both `commonName` and the SAN
  list.
- **Operator trust store regression.** `TMC Self-Managed CA` is still present and trusted in the
  System keychain, and `security verify-cert` returns success for `tmc.lab1.mmtm.ai` and
  `CSSMERR_TP_NOT_TRUSTED` for `landing.tmc.lab1.mmtm.ai` against that same store (E2). Nothing
  was removed client-side.
- **Misconfigured `sm_values.yaml`.** `serverTLS.clusterIssuer.name: local-issuer` is set and is
  demonstrably honored for four other certificates (E6). The landing template does not consult
  it.
- **Manual edit or drift.** The rendered desired state published by the package itself names
  `dev` (E4), and kapp-controller re-applies it (E9).
- **Missing DNS or VIP change.** `landing.tmc.lab1.mmtm.ai` resolves to 192.168.204.220, the
  configured Envoy VIP, and the TLS handshake completes normally.

---

## Reproduction

1. Install TMC Self-Managed **1.4.4** with `serverTLS.type: clusterIssuer` and a
   `clusterIssuer.name` naming an operator-controlled CA.
2. Confirm `landing.tmc.<domain>` serves a certificate chained to that CA, and that
   `CertificateRequest` revision 1 for `landing-service-server-tls` names
   `ClusterIssuer/<your issuer>`.
3. Visit the console in Chrome so the HSTS policy is cached over a clean connection. This step
   matters — it is what removes the bypass later.
4. Upgrade the package repository to **1.4.5** and let kapp-controller reconcile.
5. Observe `Certificate/landing-service-server-tls` advance to generation 2 with
   `issuerRef: {kind: Issuer, name: dev}`, and a revision-2 `CertificateRequest` issued by `dev`.
6. Reload the console — `ERR_CERT_AUTHORITY_INVALID` with no bypass offered.

The template diff in **Root cause** is reproducible without a cluster: pull both
package-repository bundles, follow the `tmc-local-stack` package to its nested bundle
(`0.1.3839058` for 1.4.4, `0.1.8751591` for 1.4.5), and diff
`upstream/templates/global-services/025-certificate-landing-service-server-tls.yaml`.

---

## Workarounds evaluated

**Restore the intended issuer (requires pausing the package).**

```bash
kubectl -n tmc-local patch packageinstall tanzu-mission-control \
  --type=merge -p '{"spec":{"paused":true}}'
kubectl -n tmc-local patch certificate landing-service-server-tls \
  --type=merge -p '{"spec":{"issuerRef":{"kind":"ClusterIssuer","name":"local-issuer"}}}'
kubectl -n tmc-local delete secret landing-service-tls
```

Contour watches the Ingress TLS secret and picks up the replacement without a restart. This
returns the certificate to its 1.4.4 issuer, which ran for five days in this deployment — including
whatever internal mTLS uses the same secret (E5) — so the risk is low. It is nonetheless a
workaround: the package must stay paused, which blocks all further TMC reconciliation, and the
change reverts on unpause.

**Trust the development CA on each client.**

```bash
kubectl -n tmc-local get secret dev-ca-key -o jsonpath='{.data.ca\.crt}' | base64 -d > olympus-dev-ca.crt
```

Unblocks the browser immediately but asks every operator to trust a CA that also signs 46
internal service certificates (E6), which is a far broader grant than trusting the CA they
supplied. Not acceptable as a steady state.

**Clear the cached HSTS policy.** Requires deleting both `landing.tmc.lab1.mmtm.ai` and
`tmc.lab1.mmtm.ai` in `chrome://net-internals/#hsts`, only restores the click-through warning
rather than fixing anything, and the parent policy is re-published on the next console visit
(E7).

---

## What we need

1. **Confirm the `externalIssuerRef` → `internalIssuerRef` change on
   `025-certificate-landing-service-server-tls.yaml` was unintended**, and restore
   `externalIssuerRef` as in 1.4.4. This is the whole fix.
2. **Confirm the same for `026-certificate-tenancy-service-server-tls.yaml`.** It moved in the
   same release. It is harmless in this deployment because tenancy has no public Ingress, but we
   would like to know whether that is by design or the same oversight.
3. **Was dropping the `certificateImport` guard on the landing template intentional?** The
   sibling `auth-manager` template kept its. As it stands, a bring-your-own-certificate
   deployment upgrading to 1.4.5 gets an internal-CA certificate generated over the top.
4. **Should `landing-service-tls` be one secret or two?** It is simultaneously the component's
   internal mTLS identity and the secret terminating a public Ingress, which forces a single
   issuer to satisfy both trust domains. A separate external-issuer certificate for the public
   hostname would remove the ambiguity permanently rather than reverting one token.
5. **Target release for the fix**, so we can drop the client-side trust workaround.
6. **Is any release-note or upgrade-path warning planned?** Any 1.4.4 → 1.4.5 upgrade on a
   self-signed or BYO-certificate deployment loses console access at the moment the package
   reconciles, with no browser-side recovery path (see *Note on HSTS and diagnosis*).

---

## Note on HSTS and diagnosis

This defect is materially harder to diagnose than an ordinary certificate problem, and that is
worth flagging separately. Because TMC publishes HSTS with `includeSubDomains` from the console
hostname, the very first symptom an operator sees is a terminal, non-bypassable browser error
with no certificate detail exposed — and the HSTS policy was cached precisely *because* the
endpoint was healthy beforehand. An operator with no CLI access to the cluster cannot inspect the
chain, cannot click through, and has no indication that the cause is an issuer change rather than
a network interception. Surfacing the issuer used for each externally-reachable hostname in the
installer output, or validating at reconcile time that every ingressed hostname is signed by
`serverTLS.clusterIssuer`, would turn this into a self-diagnosable condition.

---

*Case prepared 2026-08-27 · lab1 · TMC Self-Managed 1.4.5 · Contour 19.3.2 · cert-manager
1.12.10+vmware.1-tkg.1 · client macOS 26.5.2 / Chrome 151. All measurements taken from a running
system with no restarts or configuration changes applied during collection.*

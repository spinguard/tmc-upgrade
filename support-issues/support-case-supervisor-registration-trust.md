# TMC Self-Managed 1.4.5 — Supervisor registration cannot complete: the agent installer is given only public CA roots

**Summary:** Registering a vSphere Supervisor as a TMC management cluster fails at the very first
step. `tmc-agent-installer` cannot download the registration manifest, and reports
`registration link domain name verification failed`. The message names the domain, but the domain
is correct and reachable — the failure is TLS trust.

The installer's trust material comes from configmap `svc-tmc-c9/tmc-tls-cert` (key `tls.crt`),
injected as the `TMC_TLS_CERT` environment variable. WCP populates that configmap with **four
public certificate authorities** — Let's Encrypt R3, DigiCert TLS RSA SHA256 2020 CA1, ISRG Root
X1, and Entrust Root CA G2. That is the trust set for TMC **SaaS**, whose endpoints are publicly
issued. A TMC Self-Managed endpoint is signed by the operator's own CA, which is not in that list
and cannot be added to it through any supported surface.

The result is a registration path that cannot succeed on a self-managed deployment without an
out-of-band edit on the Supervisor control-plane VMs — which the vSphere SSO administrator does
not have the rights to make, and which a WCP reconcile may revert.

There is also a bootstrapping inversion: **the CA the installer needs in order to download the
manifest is shipped inside that manifest.** The manifest's own ConfigMap carries the TMC
Self-Managed CA, the Harbor CA, and the keycloak CA. Everything downstream of the first hop is
already trusted correctly. Only the fetch itself is broken.

**The fix is for the TKGS registration path to trust the operator-supplied CA — either by
templating `tmc-tls-cert` from the `serverTLS` CA for `stack_type: tmc-local` registrations, or by
exposing a CA field on the `AgentInstall` CRD.**

| Field | Value |
|---|---|
| Component | `tmc-agent-installer` (TKGS registration path) |
| Image | `localhost:5000/vmware/tmc-agent-installer:1.0` |
| Driven by | `CronJob/tmc-agent-installer`, `svc-tmc-c9`, schedule `*/1 * * * *` |
| Shipped from | `/usr/lib/vmware-wcp/objects/PodVM-GuestCluster/70-tmc-agent-installer` |
| Trust input | `configmap/tmc-tls-cert`, key `tls.crt` → env `TMC_TLS_CERT` |
| Registration type | `type=tkgs`, `stack_type: tmc-local` |
| Management cluster | `non-prod-mgr` (`mc:01M3VWYCPWTW7NXZ28SGASK8DT`) |
| Affected hostname | `tmc.lab1.mmtm.ai` |
| Required CA | `CN=TMC Self-Managed CA`, SKI `6D:93:18:EA:30:A1:17:A7:4B:AC:0C:26:30:2C:B7:8E:52:1F:14:2B` |
| Configmap created | 2026-07-29 23:41:40 UTC (never modified since) |
| Observed | 2026-10-01 14:13–14:25 UTC |
| Terminal after | 10 retries → `INSTALL_FAILED` |

---

## Root cause

`tmc-tls-cert` contains a public-CA bundle and nothing else. Decoded, all four entries are
well-known public roots and intermediates:

| # | Subject | Issuer | Validity |
|---|---|---|---|
| 1 | `CN=R3, O=Let's Encrypt` | `CN=ISRG Root X1` | Sep 4 2020 – **Sep 15 2025 (expired)** |
| 2 | `CN=DigiCert TLS RSA SHA256 2020 CA1` | `CN=DigiCert Global Root CA` | Apr 14 2021 – Apr 13 2031 |
| 3 | `CN=ISRG Root X1` | self | Jun 4 2015 – Jun 4 2035 |
| 4 | `CN=Entrust Root Certification Authority - G2` | self | Jul 7 2009 – Dec 7 2030 |

This is coherent only for TMC SaaS. `tmc.lab1.mmtm.ai` is served a certificate issued by
`CN=TMC Self-Managed CA` — the CA minted from the operator's `serverTLS.clusterIssuer` — so the
installer has no path from the leaf to a trusted root and aborts before any manifest is fetched.

Worth noting independently: **entry 1 expired on 2025-09-15** and is still being shipped in a
1.4.5-era WCP object. It is inert here, but it indicates the bundle is a static literal in the WCP
object file rather than anything derived or maintained.

### The trust the installer needs is inside the payload it cannot fetch

Fetching the manifest manually (with the CA added to the bundle out-of-band) shows that it carries
a ConfigMap with exactly the trust material required, including the CA that would have let the
installer fetch it in the first place:

| Embedded CA | SKI |
|---|---|
| `CN=Harbor CA` | `7E:92:54:3F:85:25:AD:7F:DF:39:BC:E1:B8:3E:62:4C:45:D6:94:6A` |
| `CN=keycloak.lab1.mmtm.ai` | `FB:4C:4D:72:EA:2A:37:D4:3F:E8:D0:21:74:AC:BB:0E:39:D6:F6:35` |
| `CN=TMC Self-Managed CA` | `6D:93:18:EA:30:A1:17:A7:4B:AC:0C:26:30:2C:B7:8E:52:1F:14:2B` |

So the registration service already knows which CA the agent must trust, and already ships it. The
gap is confined to the one hop that happens *before* the payload is available.

### There is no supported way to correct it

- The `AgentInstall` CRD exposes only `operation` and `registrationLink` (E9). No CA field.
- `tmc-tls-cert` is WCP-owned, and `administrator@vsphere.local` has `get` but not
  `patch`/`update` on configmaps in `svc-tmc-c9` (E8).
- No `sm_values.yaml` setting reaches it — the configmap is on the Supervisor, created by WCP, and
  the TMC deployment never writes to it.

---

## Plain-language summary

To join a Supervisor to TMC, a small installer job on the Supervisor downloads a configuration
bundle from the TMC server over HTTPS. Like any HTTPS client it must first decide whether it
trusts the certificate the server presents, which it does by consulting a list of certificate
authorities handed to it.

For the hosted version of TMC, the server's certificate comes from a commercial authority, and the
list it is handed — four well-known public authorities — is the right list.

For the self-managed version, the server's certificate is signed by the customer's own authority.
That authority is, by definition, not on the public list. The installer therefore refuses the
connection and the registration never starts.

The error it prints says the *domain name* could not be verified, which sends an operator looking
at DNS, routing, and firewalls. All of those are fine. The domain resolves correctly, the server
answers, and the TLS handshake completes — it is only the signature that is not recognised.

The circular part: the certificate authority the installer is missing is included in the very
bundle it is trying to download. The server already knows what the installer needs to trust and
already sends it; the installer just cannot get far enough to read it.

Correcting it means editing a file on the Supervisor's control-plane virtual machines as root,
which the normal vSphere administrator account cannot do, and which the platform may undo on its
next reconcile.

---

## Impact

- **A Supervisor cannot be registered as a TMC management cluster on any TMC Self-Managed
  deployment using an operator-supplied or self-signed CA.** This is the default and documented
  configuration for TMC Self-Managed; a publicly-issued certificate on the TMC endpoint is the
  exception.
- **The failure is terminal, not transient.** After 10 retries the `AgentInstall` CR moves to
  `INSTALL_FAILED` and the installer logs `no processing required` on every subsequent run. The
  cronjob keeps firing every minute and does nothing. Correcting the trust problem alone does not
  resume the install — the CR must also be reset (see *Workarounds evaluated*).
- **The diagnostic trail points away from the cause.** `registration link domain name verification
  failed` directs attention to DNS and network reachability. There is no mention of a certificate,
  no issuer or subject logged, and no indication that the trust set is a fixed public-CA list.
- **The documented remediation is unavailable to the documented operator.** The only effective
  change requires root on the Supervisor control-plane VMs via `decryptK8Pwd.py`, which is outside
  the vSphere administrator role and is not a supported configuration surface.

---

## Environment

| Component | Version | Note |
|---|---|---|
| TMC Self-Managed | 1.4.5 | `PackageInstall/tanzu-mission-control`, constraint `1.4.5`, `paused: true` |
| TMC local stack | 0.1.8751591 | `tmc-local-stack` |
| cert-manager | 1.12.10+vmware.1-tkg.1 | `cert-manager-tmcsm` |
| Contour | 19.3.2 | Envoy fronting all TMC hostnames |
| TMC cluster | `tmc` context | namespace `tmc-local` |
| Supervisor (registering) | v1.32.7+vmware.5-fips | 192.168.204.194, 3 control-plane VMs, Photon OS 5.10.245-1.ph4-esx |
| TMC service namespace | `svc-tmc-c9` | created 2026-07-29 23:41:40 UTC |
| Envoy LB VIP | 192.168.204.220 | `contourEnvoy.loadBalancerIP` |
| TMC endpoint leaf | `CN=tmc.lab1.mmtm.ai` | issued Sep 29 2026 17:08:59 UTC, expires Sep 30 2027 |
| Client | macOS 26.5.2 | `TMC Self-Managed CA` trusted in System keychain |

`PackageInstall/tanzu-mission-control` is paused deliberately, per the landing-certificate issue
documented in `support-case-landing-cert-issuer.md`. That is unrelated to this defect — it affects
`landing.tmc.lab1.mmtm.ai` and a different issuer — but it is why the package shows `paused: true`.

---

## Evidence

### E1 — The installer fails on the first attempt, within the same second

```
$ kubectl --context 192.168.204.194 logs tmc-agent-installer-29847734-ljqls -n svc-tmc-c9
{"command":"INSTALL","component":"installer","extension":"tmc-agent-installer","level":"info","msg":"found non-terminal state in install CR","time":"2026-10-01T14:14:02Z"}
{"component":"installer","extension":"tmc-agent-installer","level":"info","msg":"downloading manifest from link: https://tmc.lab1.mmtm.ai/installer?id=<redacted>\u0026source=registration\u0026type=tkgs","time":"2026-10-01T14:14:02Z"}
{"error":"download and apply registration link, attempt: 1: registration link domain name verification failed","extension":"tmc-agent-installer","level":"fatal","msg":"process of install / uninstall","time":"2026-10-01T14:14:02Z"}
```

Download start and fatal error share the same timestamp to the second. There is no connect
timeout, no DNS retry, no partial transfer — the failure is local to certificate validation. A
network or name-resolution fault would not present this way.

### E2 — The CR retries ten times and then stops permanently

```
$ kubectl get agentinstall tmc-agent-installer-config -n svc-tmc-c9 -o jsonpath='{.status}'
{"message":"registration link domain name verification failed","retryCount":10,"status":"INSTALL_FAILED"}

$ kubectl logs -n svc-tmc-c9 -l job-name --tail=-1       # 14:25:02, after the tenth failure
{"extension":"tmc-agent-installer","level":"info","msg":"no processing required","time":"2026-10-01T14:25:02Z"}
```

The earlier runs logged `found non-terminal state in install CR`; once `INSTALL_FAILED` is
recorded the installer no longer acts. The cronjob continues to fire every minute and exits as a
no-op. This matters for remediation: fixing trust is necessary but not sufficient.

### E3 — The endpoint is signed by a private CA and presents a bare leaf

```
$ echo | openssl s_client -connect tmc.lab1.mmtm.ai:443 -servername tmc.lab1.mmtm.ai -showcerts \
    | openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -noout
subject=CN=tmc.lab1.mmtm.ai
issuer=CN=TMC Self-Managed CA

notBefore=Sep 29 17:08:59 2026 GMT
notAfter=Sep 30 13:08:59 2027 GMT
X509v3 Authority Key Identifier: 6D:93:18:EA:30:A1:17:A7:4B:AC:0C:26:30:2C:B7:8E:52:1F:14:2B
X509v3 Subject Alternative Name: DNS:tmc.lab1.mmtm.ai
```

One certificate is served — the leaf, no issuer. The hostname is present in both `commonName` and
the SAN, so this is not a name-matching failure.

### E4 — The trust set handed to the installer contains only public roots

```
$ kubectl get cm tmc-tls-cert -n svc-tmc-c9 -o jsonpath='{.data.tls\.crt}' | grep -c 'BEGIN CERT'
4
```

Decoded, those four are the public CAs tabulated in **Root cause**. `CN=TMC Self-Managed CA` is
absent. The configmap is wired straight into the container:

```yaml
env:
- name: TMC_TLS_CERT
  valueFrom:
    configMapKeyRef:
      key: tls.crt
      name: tmc-tls-cert
```

### E5 — The leaf does not verify against that bundle, and does verify against the TMC-SM CA

```
$ openssl verify -CAfile cm-tls.crt leaf-tmc.pem
CN=tmc.lab1.mmtm.ai
error 20 at 0 depth lookup: unable to get local issuer certificate
error leaf-tmc.pem: verification failed

$ openssl verify -CAfile tmcsm-ca.pem leaf-tmc.pem
leaf-tmc.pem: OK
```

Against the live endpoint, with the system trust store excluded:

```
$ echo | openssl s_client -connect tmc.lab1.mmtm.ai:443 -servername tmc.lab1.mmtm.ai \
      -CAfile cm-tls.crt -verify_return_error
verify error:num=20:unable to get local issuer certificate
Verify return code: 20 (unable to get local issuer certificate)

$ ... -CAfile <cm-tls.crt + TMC-SM CA>
Verify return code: 0 (ok)
```

Adding one certificate to the bundle is the difference between failure and success.

### E6 — The required CA is the one minted from `serverTLS.clusterIssuer`

```
$ kubectl --context tmc get secret local-issuer-cluster-issuer-ca-key -n cert-manager \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectKeyIdentifier,basicConstraints
subject=CN=TMC Self-Managed CA
issuer=CN=TMC Self-Managed CA
notBefore=Mar 25 18:56:18 2026 GMT
notAfter=Mar 22 18:56:18 2036 GMT
X509v3 Subject Key Identifier: 6D:93:18:EA:30:A1:17:A7:4B:AC:0C:26:30:2C:B7:8E:52:1F:14:2B
X509v3 Basic Constraints: critical CA:TRUE
```

Its Subject Key Identifier matches the Authority Key Identifier on the leaf in E3. This is the CA
the operator configured via `serverTLS.clusterIssuer` (`local-issuer`), and the one already
trusted on operator clients. TMC knows it: it is shipped in the registration manifest (E7).

### E7 — The registration manifest carries the CA the installer lacks

Fetched manually with the corrected bundle:

```
$ python3 -c '...urlopen(link, context=ssl.create_default_context(cafile="fixed-bundle.crt"))...'
bytes: 13050
```

Its ConfigMap embeds three CAs — Harbor, keycloak, and `CN=TMC Self-Managed CA` with SKI
`6D:93:18:…:14:2B`, byte-identical to E6 — alongside:

```yaml
tmc_host: tmc.lab1.mmtm.ai
tmc_url: https://tmc.lab1.mmtm.ai
stack_type: tmc-local
management_cluster_name: non-prod-mgr
```

The payload also knows it is a self-managed registration (`stack_type: tmc-local`). The
information needed to set up trust correctly exists on the server side at manifest-generation
time; it is simply not available to the client before the download.

### E8 — The configmap is WCP-owned and not writable by the vSphere administrator

```
$ kubectl --context 192.168.204.194 auth can-i patch configmaps -n svc-tmc-c9
no
$ kubectl --context 192.168.204.194 auth can-i update configmaps -n svc-tmc-c9
no
$ kubectl --context 192.168.204.194 auth can-i get configmaps -n svc-tmc-c9
yes
```

As `sso:Administrator@vsphere.local`. Ownership is recorded on the object itself:

```yaml
annotations:
  kubernetes.io/change-cause: kubectl apply --filename=/usr/lib/vmware-wcp/objects/PodVM-GuestCluster/70-tmc-agent-installer --record=true
  tmc.cloud.vmware.com/orphan-resource: "true"
labels:
  tmc.cloud.vmware.com/exclude-from-detach: "true"
```

`managedFields` shows a single apply and no subsequent writes since 2026-07-29. The only route to
changing it is root on a control-plane VM, obtained via `decryptK8Pwd.py` on vCenter.

For contrast, the CR *is* writable, which is why the reset in *Workarounds* is possible:

```
$ kubectl auth can-i patch agentinstalls -n svc-tmc-c9           # yes
$ kubectl auth can-i delete agentinstalls -n svc-tmc-c9          # yes
$ kubectl auth can-i patch agentinstalls/status -n svc-tmc-c9     # yes
$ kubectl auth can-i patch cronjobs -n svc-tmc-c9                # no
$ kubectl auth can-i delete pods -n svc-tmc-c9                   # no
```

### E9 — The `AgentInstall` CRD has no CA field

```
$ kubectl explain agentinstall.spec --recursive
GROUP:   installers.tmc.cloud.vmware.com
KIND:    AgentInstall
VERSION: v1alpha1
FIELDS:
  operation	<string>
  registrationLink	<string>
```

Two fields. There is no way to supply trust material alongside the registration link, so the
natural fix — attach the CA to the thing that names the endpoint — is not expressible.

### E10 — The stored bundle has no trailing newline

```
$ kubectl get cm tmc-tls-cert -n svc-tmc-c9 -o jsonpath='{.data.tls\.crt}' | tail -c 20 | od -c
0000000    E   N   D       C   E   R   T   I   F   I   C   A   T   E   -
0000020    -   -   -   -
0000024
```

The value ends immediately after `-----END CERTIFICATE-----`. A naive `cat old new` therefore
yields `-----END CERTIFICATE----------BEGIN CERTIFICATE-----` and an unparseable bundle
(`curl: (77) error setting certificate verify locations`). Any remediation must interpose a
newline. Noted because it silently produces a *worse* state than the original.

---

## Ruled out

- **DNS, routing, or reachability.** `tmc.lab1.mmtm.ai` resolves to 192.168.204.220, the
  configured Envoy VIP. The TCP connection and TLS handshake both complete; the server returns
  HTTP 200 for the registration link and a 13050-byte manifest once trust is supplied (E7). The
  installer runs with `hostNetwork: true` on the control-plane VMs, which have the same path.
- **Firewall or egress proxy.** A blocked or intercepted connection cannot produce a fatal error
  in the same second as the request, and would not be repaired by adding a CA to a local bundle
  (E5).
- **An expired or invalid registration token.** The link returns the correct manifest for
  `non-prod-mgr` with a valid `access_token_info` and `cluster_rid` (E7). The token is fine; the
  installer never gets to use it.
- **Expired endpoint certificate.** `notBefore=Sep 29 2026`, `notAfter=Sep 30 2027` (E3). Current.
- **Hostname or SAN mismatch** — despite what the error message says. `tmc.lab1.mmtm.ai` appears
  in both `commonName` and `subjectAltName` (E3), and the same leaf verifies cleanly once the
  issuer is available (E5). The wording of the error is misleading.
- **Harbor or registry trust.** The installer image is pulled from `localhost:5000` on the
  Supervisor and starts normally. The Harbor CA (`7e9254`) is current and is carried in the
  manifest for the downstream bootstrapper (E7). The failure is before any registry access.
- **The `landing` certificate defect** (`support-case-landing-cert-issuer.md`). Different
  hostname, different issuer (`Olympus Development CA`), different direction of travel. The
  endpoint here is signed by the *correct* CA; the client simply does not have it.
- **Agent-side or downstream trust.** The manifest ships all three CAs the agent needs (E7). Only
  the installer's own first hop lacks trust.
- **Operator client trust store.** `TMC Self-Managed CA` is trusted in the macOS System keychain
  and the console is reachable. This is a Supervisor-side trust set, independent of any client.
- **A stale or drifted configmap.** `managedFields` records a single apply and no modification
  since creation (E8). The bundle is what WCP shipped, unaltered.

---

## Reproduction

1. Deploy TMC Self-Managed 1.4.5 with `serverTLS.type: clusterIssuer` and a `clusterIssuer.name`
   naming an operator-controlled CA, so that `tmc.<domain>` is signed by a private CA. (Equally:
   any self-signed or BYO-CA deployment — anything other than a publicly-issued endpoint
   certificate.)
2. Enable Workload Management on a Supervisor and confirm `svc-tmc-c9` exists with
   `configmap/tmc-tls-cert` and `CronJob/tmc-agent-installer`.
3. Confirm the shipped bundle holds only public roots:
   `kubectl get cm tmc-tls-cert -n svc-tmc-c9 -o jsonpath='{.data.tls\.crt}' | openssl storeutl -noout -text /dev/stdin | grep Subject:`
4. In the TMC console, register a management cluster of type **Supervisor / TKGS** and copy the
   registration link.
5. Apply the `AgentInstall` CR with that `registrationLink` and `operation: INSTALL`.
6. Observe `tmc-agent-installer-*` pods in `svc-tmc-c9` enter `Error`, each logging
   `registration link domain name verification failed` on attempt 1.
7. After ten minutes, observe `AgentInstall.status` at `retryCount: 10`,
   `status: INSTALL_FAILED`, and subsequent pods logging `no processing required`.

The trust failure is reproducible without a Supervisor: extract the bundle from `tmc-tls-cert`,
and run `openssl verify -CAfile <bundle> <leaf from the TMC endpoint>`. It returns error 20.

Two traps when reproducing on macOS, both of which manufacture false negatives:

- `curl --cacert <bundle>` returns **HTTP 200**. System `curl` validates against the Secure
  Transport keychain and ignores `--cacert`; if the operator has trusted the CA locally — which
  they must have, to use the console — the test silently passes. Use `openssl verify -CAfile`.
- Python 3.13+ enables `ssl.VERIFY_X509_STRICT` by default and rejects the CA outright with
  `CA cert does not include key usage extension`, independent of this defect (see below).

---

## Workarounds evaluated

**Append the CA to `tmc-tls-cert` from a Supervisor control-plane VM (effective; not supported,
not durable).**

The only change that makes registration work. Requires root on a control-plane VM via
`/usr/lib/vmware-wcp/decryptK8Pwd.py` on vCenter. One VM suffices — the configmap lives in etcd
and is shared.

```sh
kubectl -n svc-tmc-c9 get cm tmc-tls-cert -o jsonpath='{.data.tls\.crt}' > /tmp/b.crt
printf '\n' >> /tmp/b.crt                 # required: see E10
cat /tmp/tmcsm-ca.pem >> /tmp/b.crt
openssl verify -CAfile /tmp/b.crt /tmp/leaf-tmc.pem   # confirm OK before applying
kubectl -n svc-tmc-c9 create cm tmc-tls-cert --from-file=tls.crt=/tmp/b.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

The CA is `resources/tmcsm-ca.pem`, sourced from `cert-manager/local-issuer-cluster-issuer-ca-key`
on the TMC cluster.

Two caveats. The object is applied from `/usr/lib/vmware-wcp/objects/PodVM-GuestCluster/70-tmc-agent-installer`,
so a WCP reconcile, a `wcpsvc` restart, or a control-plane VM rollout can revert it — and the
revert would de-register silently at the next agent operation rather than at a predictable moment.
And because `tmc-tls-cert` is a Supervisor-wide object, this grants the edit for every TMC
registration on that Supervisor, not just the intended one.

**Reset the `AgentInstall` CR after correcting trust (required).**

`INSTALL_FAILED` is terminal (E2); the corrected bundle alone changes nothing. The CR is writable
by the SSO administrator (E8), so either delete and re-apply:

```sh
kubectl --context 192.168.204.194 delete agentinstall tmc-agent-installer-config -n svc-tmc-c9
kubectl --context 192.168.204.194 apply -f tmp/agentinstall.yaml
```

or clear the status in place:

```sh
kubectl --context 192.168.204.194 patch agentinstall tmc-agent-installer-config -n svc-tmc-c9 \
  --subresource=status --type=merge \
  -p '{"status":{"status":"INSTALLATION_IN_PROGRESS","retryCount":0,"message":""}}'
```

The cronjob fires every minute, so the next run picks it up. Note the ten-retry budget is ten
*minutes* — ample time to burn through it while diagnosing, which is how this deployment reached a
terminal state during investigation.

**Patch the configmap through the Supervisor API — not possible.** `patch` and `update` on
configmaps in `svc-tmc-c9` are denied to `administrator@vsphere.local` (E8). This is the route an
operator would expect to use.

**Supply the CA on the `AgentInstall` CR — not expressible.** The CRD has two fields (E9).

**Put a publicly-trusted certificate on the TMC endpoint — avoids the defect entirely.** Issue
`tmc.<domain>` from a CA chaining to one of the four roots in the shipped bundle. This is the only
configuration in which the TKGS registration path works as shipped. It is not viable for an
air-gapped or internal-DNS deployment, and it is not how TMC Self-Managed is documented to be
deployed.

**Add the CA to vCenter's trusted root certificates — unverified.** If WCP propagated vCenter's
trusted roots into `tmc-tls-cert` this would be the natural supported surface. The shipped bundle
is four unrelated public CAs with one already expired, which strongly suggests a static literal
rather than anything derived from vCenter trust. We have not confirmed either way, and it is
question 2 below.

---

## What we need

1. **Confirm whether the TKGS registration path is expected to work at all on a TMC Self-Managed
   deployment with an operator-supplied CA.** If it is, the shipped `tmc-tls-cert` bundle cannot be
   the intended trust source, and we would like to know what is. If it is not, this needs to be
   stated in the TMC Self-Managed documentation, because nothing in the registration flow or the
   console indicates it.
2. **Is `tmc-tls-cert` intended to be derived from anything** — vCenter's trusted root store, the
   `serverTLS` CA, a `sm_values.yaml` key — or is it a static literal in the WCP object file? This
   determines whether a supported remediation surface exists today.
3. **Please consider templating `tmc-tls-cert` for `stack_type: tmc-local` registrations, or
   exposing a CA field on the `AgentInstall` CRD.** The registration service already knows the
   stack type and already ships the correct CA in the manifest (E7); the information is present on
   the server and merely arrives one hop too late. Either change removes the bootstrapping
   inversion.
4. **Fix the error message.** `registration link domain name verification failed` for a
   certificate-chain failure sends operators to DNS, firewalls, and proxies. Logging the issuer and
   subject of the certificate received, and the fact that the trust set came from `TMC_TLS_CERT`,
   would have shortened this diagnosis from hours to minutes.
5. **Reconsider the ten-retry terminal state, or make recovery discoverable.** A trust
   misconfiguration is operator-correctable, but the CR latches to `INSTALL_FAILED` within ten
   minutes and the installer then logs only `no processing required` — which reads as success. An
   operator who fixes trust afterwards sees nothing happen and has no indication that the CR
   needs resetting.
6. **The bundle ships an expired certificate.** Let's Encrypt R3 expired 2025-09-15. Harmless in
   the self-managed case, but it should be refreshed, and its presence suggests the bundle is not
   being maintained.
7. **Target release for the fix**, so we can drop the control-plane-VM edit before it is reverted
   by a WCP reconcile we do not control.

---

## Note on the CA's missing `keyUsage` extension

Surfaced while reproducing this and worth recording separately, as it is a latent issue rather
than part of the defect above.

`CN=TMC Self-Managed CA` — generated by cert-manager from `serverTLS.clusterIssuer` — carries
`basicConstraints: critical, CA:TRUE` but **no `keyUsage` extension**. RFC 5280 recommends
`keyCertSign` on a CA certificate but does not require the extension to be present.

Verifiers disagree on this. Go's `crypto/x509` gates the check on the extension being present
(`if parent.KeyUsage != 0 && parent.KeyUsage&KeyUsageCertSign == 0`), so an absent `keyUsage` is
treated as unrestricted and accepted — which is why the Go-based installer will accept this CA
once it is in the bundle, and why the fix above works. `openssl verify` likewise accepts it in its
default (non-strict) mode. But strict verifiers reject it:

```
$ python3 -c '...create_default_context(cafile="fixed-bundle.crt")...'
ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
CA cert does not include key usage extension
```

Python 3.13 enabled `ssl.VERIFY_X509_STRICT` by default, so this now fails out of the box for any
Python client — including tooling an operator might reasonably write against a TMC-SM endpoint.
Adding `keyUsage: [digital signature, key encipherment, cert sign]` to the CA `Certificate` spec
would close this off before it becomes a second support case.

(The installer being Go is inferred from its logrus-style JSON log output, not confirmed from
source. The empirical result in E5 — that the handshake succeeds with the CA added — holds
regardless.)

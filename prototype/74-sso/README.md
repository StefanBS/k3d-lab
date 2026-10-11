# PROTOTYPE: single sign-on for the Lab's UIs (#74)

Throwaway. It answers five questions the design for #74 left open, by putting Dex, oauth2-proxy and an `ExternalAuth` filter on a running Lab by hand. Nothing here is production code: the real change goes in `platform/` and `scripts/`.

Run on 2026-10-11 against a Lab on `main` at 45a53c4: k3s v1.37.1, Cilium 1.20.2, Gateway API v1.6.3, ESO 2.12.0, Dex v2.46.0, oauth2-proxy v7.15.5.

## Running it

- `./up.sh store crds secrets dex dns proxy route argocd grafana` on a running Lab. Each step is one function in `up.sh`. It pauses `gateway-api`, `hubble`, `argocd` and `grafana`, and writes to the Secret Store under `lab/platform/sso/`.
- `./login.sh <url> [<cookie jar>]` logs in as a browser would, with curl, and prints each hop.
- `./down.sh` takes it all back, in the Lab and in the Secret Store.

## Verdict

| # | Question | Held? |
|---|---|---|
| 1 | `ExternalAuth` filter syntax on Cilium 1.20.2 | Yes: the upstream form, `type: ExternalAuth` |
| 2 | oauth2-proxy answers the filter with a redirect to Dex, and returns to the UI | Yes, with `--upstream=static://200` |
| 3 | `coredns-custom` picked up without restarting CoreDNS | Yes, in 50 to 85 seconds |
| 4 | ArgoCD, Grafana and oauth2-proxy resolve `sso.lab.localhost` through DNS | Yes, but **not with the rewrite to the Gateway's Service** |
| 5 | ESO renders the bcrypt hash | Yes: `{{ .password \| bcrypt }}` |

No fallback from the handoff was needed. Two parts of the design must change: what the CoreDNS entry answers (point 4), and how the experimental CRDs get installed (point 1).

## 1. The filter

`manifests/50-hubble-route.yaml`. The route keeps pointing at the real Service.

```yaml
rules:
  - filters:
      - type: ExternalAuth
        externalAuth:
          protocol: HTTP
          backendRef: {name: oauth2-proxy, namespace: sso, port: 80}
          http:
            allowedHeaders: [cookie, x-forwarded-proto]
    backendRefs:
      - {name: hubble-ui, port: 80}
```

- Cilium picked the filter up as soon as the CRDs were experimental. No restart of the operator, the agents or Envoy.
- A `ReferenceGrant` in `sso` is needed for a route in another namespace (`manifests/40-oauth2-proxy.yaml`).
- The auth check works when oauth2-proxy runs on a different node from Envoy (cilium/cilium#46768 didn't show).
- Envoy's timeout for the HTTP check is 10 s. The 200 ms limit in cilium/cilium#48354 is for `protocol: GRPC`.
- `GatewayClass` `cilium` doesn't list `HTTPRouteExternalAuth` in its `supportedFeatures`, and Cilium's 1.20 Gateway API docs don't mention the filter. It works all the same.

**Surprise: k3s installs Gateway API CRDs itself.** Its `gateway-api-crd` addon (a HelmChart in `kube-system`) installs the standard channel at server start, with the `safe-upgrades` ValidatingAdmissionPolicy. That policy refuses experimental CRDs on top of standard ones:

> Installing experimental CRDs on top of standard channel CRDs is prohibited by default. Uninstall ValidatingAdmissionPolicy safe-upgrades.gateway.networking.k8s.io to install experimental CRDs on top of standard channel CRDs.

So switching `platform/gateway-api` to `experimental-install.yaml` isn't enough: `just up` and ArgoCD's sync would both be refused. The prototype deleted the policy and its binding, then applied the bundle, which brings the policy back; it then allows updates to experimental CRDs. For the spec to decide:

- `just up` deletes the policy before it applies the CRDs, or
- k3s is kept from installing the addon. `gateway-api-crd` isn't among the values `k3s server --disable` lists. Untested.
- The addon's chart has `experimental.enabled`, but that only adds the `x-k8s.io` CRDs. Its HTTPRoute has no `ExternalAuth`.

**Surprise: the filter is one per listener.** Cilium adds one `ext_authz` filter to the whole https listener and disables it per route on every other route. Consequences seen or reported:

- While oauth2-proxy's only pod was being replaced, Hubble UI answered 403 for about 10 seconds (the filter fails closed). The other UIs kept answering.
- cilium/cilium#49132, open, affects 1.20.2: deleting a route that has the filter makes other routes of the Gateway answer 403 on connections that were already open. Not reproduced here.

## 2. oauth2-proxy

`manifests/40-oauth2-proxy.yaml`. What mattered:

- `--upstream=static://200`, not 202: Envoy takes only 200 as allowed. Anything else goes back to the browser as it is, so the 302 to Dex, and its cookies, arrive.
- No `--redirect-url`, and no route for oauth2-proxy itself. The callback is `https://<the UI>/oauth2/callback`: the filter sends it to oauth2-proxy like any other request, and its 302 back to the page is what the browser gets. Each UI's callback must be in the Dex client's `redirectURIs`.
- `--reverse-proxy=true`, with `x-forwarded-proto` in the filter's `allowedHeaders`. Without them the callback URL would be `http://`.
- `cookie` in `allowedHeaders`: Envoy forwards only Host, Method, Path, Content-Length and Authorization otherwise.
- `--approval-prompt=auto`. The default, `force`, makes Dex show its approval page in spite of `skipApprovalScreen: true`.
- `--cookie-domain=.lab.localhost` and `--whitelist-domain=.lab.localhost`. The session cookie came back for `.lab.localhost`. Only Hubble UI had the filter, so a second UI opening without a login wasn't tested directly.
- The cookie secret is in the Secret Store beside the client secret, so a session outlives oauth2-proxy's pod.

`./login.sh 'https://hubble.lab.localhost/?probe=1'` ended on that same URL, query string included, with Hubble UI's page. Without a cookie, every path answers 302, POSTs included.

Not tested: a real browser. Hubble UI's gRPC-web stream passed the auth check, but nobody watched flows arrive.

## 3. `coredns-custom`

The Lab's Corefile has `import /etc/coredns/custom/*.override` in its server block, and CoreDNS mounts the ConfigMap `coredns-custom` as optional. Created after CoreDNS had run for hours, the entry answered after 85 seconds. A later change to it answered after 52 seconds. CoreDNS logged `Reloading` and didn't restart.

## 4. The back-channel

**The designed rewrite fails.** `rewrite name sso.lab.localhost cilium-gateway-lab.gateway.svc.cluster.local` resolves, but the Service's ClusterIP only answers from pods on the Server, where the Gateway's Envoy listens on the host network. From a pod on `k3d-lab-agent-0`, ports 80 and 443 of the ClusterIP time out. oauth2-proxy happened to run on the Server and worked; ArgoCD's server ran on the agent and answered:

> failed to query provider "https://sso.lab.localhost": Get "https://sso.lab.localhost/.well-known/openid-configuration": dial tcp 10.43.177.142:443: i/o timeout

**What works:** CoreDNS answers with the Server's address, `LAB_SERVER_IP`, which is already a pinned fact in Git. It's reachable on 443 from pods on both k3d Nodes. `manifests/30-coredns-custom.yaml`:

```
template IN A sso.lab.localhost {
  answer "{{ .Name }} 60 IN A 172.28.0.2"
}
template IN AAAA sso.lab.localhost {
  rcode NOERROR
}
```

With that, all three clients asked DNS for `sso.lab.localhost`, as expected of Go programs, and completed a login. No `hostAliases` needed. Not tested from a pod on the GPU Node; no client of Dex runs there.

**Trust.** Each client needs the Lab CA. The prototype copied a `lab-ca` ConfigMap into `sso`, `argocd` and `monitoring` by hand; the spec must say who makes them (`just up` already makes the one in `external-secrets`).

- oauth2-proxy: `--provider-ca-file`.
- ArgoCD: the ConfigMap mounted as `/etc/ssl/certs/lab-ca.crt` on `argocd-server`. This keeps the CA out of `oidc.config`'s `rootCA`, which would put a machine's certificate in Git.
- Grafana: `tls_client_ca` under `auth.generic_oauth`.

**ArgoCD** (`argocd()` in `up.sh`): `oidc.config` with `clientSecret: $argocd-sso:clientSecret`, from a Secret that ESO labels `app.kubernetes.io/part-of: argocd`. RBAC is `scopes: "[email]"` and `g, lab@lab.localhost, role:admin`. The Lab login could delete Applications and clusters; the local admin still logged in. With `allowedAudiences: [argocd, verify]`, ArgoCD's API also accepts the token Verify gets from the password grant, as a Bearer token.

**Grafana** (`manifests/70-grafana-patch.yaml`): the role mapping is `email == 'lab@lab.localhost' && 'Admin' || 'Viewer'`. With backticks around the strings it silently gave Viewer. The Lab login got org role Admin; anonymous viewing and the local admin still worked. Whether Grafana's API accepts Verify's token wasn't tested; it would need `auth.jwt`.

## 5. The hash, and the Secret Store

`manifests/10-secrets.yaml`. `LAB_LOGIN_HASH: '{{ .password | bcrypt }}'` in an ExternalSecret's template gives a `$2a$10$` hash. Dex reads it with `hashFromEnv`, and client secrets with `secretEnv`, so Dex's config is a plain ConfigMap with no secret in it. Dex's password grant accepted the Secret Store's password and refused a wrong one. `refreshInterval: "0"` renders the hash once.

The second role worked as designed: policy `eso-platform` on `lab/data/platform/*`, role `eso-platform` bound to the ServiceAccount `external-secrets-platform`, and a `ClusterSecretStore` with `conditions: [{namespaces: [...]}]`. The new ServiceAccount needs its own ClusterRoleBinding to `system:auth-delegator`: the chart's `systemAuthDelegator` only covers ESO's own.

## Other surprises

- **The Lab login signs in with its email.** Dex's password form and password grant take `lab@lab.localhost`. `lab` is refused: `username` is only a claim.
- **A Dex restart didn't end sessions.** With in-memory storage Dex makes new signing keys at each start. Straight after a restart, the oauth2-proxy cookie and ArgoCD's cookie from before it still worked, and a new login worked. Not watched for longer than that.
- The Verify-only client is `public: true` with no redirect URI, so it can only use the password grant.

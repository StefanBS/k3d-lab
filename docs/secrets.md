# Secrets

Workloads get their secrets as Kubernetes Secrets from **External Secrets Operator** (`platform/external-secrets/`), which reads them from the Secret Store on the Host. Secrets never go in Git, and survive `just down`. The Platform's own, the Lab login and the OIDC clients' secrets, are there too, out of every Workload's reach.

Each secret lives in OpenBao's KV v2 mount `lab/`, at `lab/workloads/<workload>/<key>`, and holds one or more fields. Write one with:

```sh
just secret-store bao kv put -mount=lab workloads/<workload>/<key> <field>=<value>
```

A Workload asks for it with an ExternalSecret in its own folder, in Git, from the ClusterSecretStore `secret-store`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <secret>
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: secret-store
  target:
    name: <secret>  # the Kubernetes Secret ESO creates
  data:
    - secretKey: <key in the Secret>
      remoteRef:
        key: workloads/<workload>/<key>
        property: <field>
```

- **How ESO logs in:** with OpenBao's Kubernetes auth, as the role `eso`, which can only read `lab/workloads/*`. `just up` points that auth at each new Lab, and nothing in the Lab holds a token of OpenBao's: OpenBao checks each of ESO's short-lived tokens with a TokenReview made with that same token, and accepts only tokens meant for it (the audience `k3d-lab-secret-store`), so no other token of ESO's service account can log in. ESO reaches OpenBao at `https://host.k3d.internal:8200`, the Host's address on the Lab network, which only ESO's controller resolves (through its pod's `hostAliases`), and trusts its certificate through the Lab CA.
- **The Platform's secrets** live at `lab/platform/`, which the role `eso` can't read. ESO reads them as a second role, `eso-platform`, bound to a ServiceAccount of its own, behind the ClusterSecretStore `secret-store-platform`, which only the namespaces `sso`, `argocd` and `monitoring` may use ([ADR 0013](adr/0013-single-sign-on-is-a-standalone-dex-with-the-lab-login-in-the-secret-store.md)).
- **What's kept on the Host:** `~/.local/share/k3d-lab/secret-store/` holds OpenBao's Raft data, its unseal key, and `init.json` with the root token and recovery key. The unseal key sits next to the data, so encryption at rest is mostly for show. `just secret-store bao` uses the root token.

## Backup and restore

`just secret-store backup <path>` stops OpenBao for a few seconds, archives that whole directory, and starts it again. The archive can read every secret, so keep it somewhere safe.

To restore an archive, on this Host or a new one:

```sh
systemctl --user stop k3d-lab-secret-store
mv ~/.local/share/k3d-lab/secret-store ~/.local/share/k3d-lab/secret-store.old
tar -xzf <archive> -C ~/.local/share/k3d-lab
just host setup
```

`just host setup` starts OpenBao on the restored data, and renews its certificate if the Lab CA is a new one. Once it works, delete `secret-store.old`.

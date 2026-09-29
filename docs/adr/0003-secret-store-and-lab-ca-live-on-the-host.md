# The Secret Store and the Lab CA live on the Host, outside the Lab

The Lab is disposable: `just down && just up` recreates it from scratch. Real Workloads such as LLMs still need secrets that outlive it, and browsers and OpenBao need a CA that is trusted once rather than on every rebuild. So both live on the Host, not in the cluster.

- **The Secret Store** is OpenBao, running as a rootless Podman Quadlet (a user systemd unit) with file storage. It unseals automatically from a key file on the Host, and the firewall lets only the Lab's Docker subnet reach it.
- **External Secrets Operator** logs in to OpenBao with Kubernetes auth. `just up` re-points that auth at each new cluster.
- **The Lab CA** is generated once by `just host-setup` and trusted by the Host. `just up` loads it into cert-manager as a CA issuer. The same CA signs OpenBao's certificate.

## Considered Options

- **Vault or OpenBao inside the Lab**: it would be destroyed on every teardown and would need unsealing after every restart.
- **Bitwarden Secrets Manager through ESO**: no vault to run, but it's a separate product from the existing Password Manager subscription, needs `bitwarden-sdk-server` and internet access, and can only look up secrets by ID.
- **SOPS + age in Git**: would put encrypted secrets in a public repo, and doesn't teach the ESO pattern.
- **A self-signed CA from cert-manager inside the Lab**: it would be a new CA after every rebuild, so it would have to be trusted again each time, and OpenBao couldn't use it.

## Consequences

- The Host holds the only state that survives the Lab. `just vault-backup` archives OpenBao's data directory and its unseal key.
- The unseal key sits next to the data it protects, so encryption at rest is mostly cosmetic. That is acceptable for a Lab.
- `just down` never touches OpenBao or the CA.

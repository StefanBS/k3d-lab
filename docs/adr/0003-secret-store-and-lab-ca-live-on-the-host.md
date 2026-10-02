# The Secret Store and the Lab CA live on the Host, outside the Lab

The Lab is disposable: `just down && just up` recreates it from scratch. Real Workloads such as LLMs still need secrets that outlive it, and browsers and OpenBao need a CA that is trusted once rather than on every rebuild. So both live on the Host, not in the cluster.

- **The Secret Store** is OpenBao, running as a rootless Podman Quadlet (a user systemd unit) with single-node Raft storage: OpenBao 2.7 dropped file storage, and Raft still keeps everything in one directory. It unseals automatically from a key file on the Host with the `static` seal, and a firewalld policy lets only the Lab's Docker subnet reach it. The policy runs before every zone, because the Lab's bridge is in Docker's zone, which accepts everything, while Fedora Workstation's default zone accepts every port above 1024 from the LAN.
- **External Secrets Operator** logs in to OpenBao with Kubernetes auth. `just up` re-points that auth at each new cluster. OpenBao holds no token of the Lab's: it reviews each login's token with that same token.
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
- Every Lab UI lives at `*.lab.localhost`. `.localhost` is reserved for loopback (RFC 6761), so browsers, `curl` and the Host's resolver send it to `127.0.0.1` without DNS, offline too. It's one level deeper than `*.localhost` because browsers reject wildcard certificates directly below a top-level name. `localtest.me` was the first choice, but it's a privately owned public domain that needs internet DNS and can be blocked by DNS rebinding protection.
- The Lab CA carries name constraints: it can only sign for `lab.localhost`, `k3d.internal`, the Lab's subnet and loopback. The Host trusts it everywhere and its key isn't encrypted, so a leaked key can only impersonate the Lab. A name outside these means generating and trusting a new CA.

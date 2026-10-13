# k3d-lab

A disposable Kubernetes Lab on one workstation: k3d with Cilium, managed through GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling. `CONTEXT.md` defines the Lab's vocabulary, `docs/` explains each part of it (see How the Lab works), and `docs/adr/` records why it's built this way.

## Prerequisites

- **Docker CE**, running as root ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)); `just host setup` installs it. The Lab's recipes always use Docker CE's socket, whatever your `DOCKER_HOST` says.
- **[mise](https://mise.jdx.dev/installing-mise.html)**, activated in your shell. It installs every other tool (`k3d`, `kubectl`, `helm`, `just`, `yq`, `shellcheck`, `bats`, `kubeconform`) at the versions pinned in `mise.toml`, the same ones CI uses. Once, in this repo:

  ```sh
  mise trust && mise install
  ```

  The Lab's recipes use those versions whatever else is on your `PATH`.

- **Ports 80 and 443 free on the Host**: the Lab serves its UIs on them, on loopback.

`just doctor` checks all of this and prints hints for anything missing.

## Preparing the Host

Once per Host, run:

```sh
just host setup
```

It prepares what outlives any Lab and is safe to re-run: a run with nothing to do says so.

- **Docker CE** ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)): installed with its data in `/home/docker-data` (labelled for SELinux like `/var/lib/docker`), started at boot, and usable without sudo through the `docker` group. If `podman-docker` is installed, `dnf` refuses Docker CE until you remove it (`sudo dnf remove podman-docker`); Podman itself can stay.
- **The Lab CA** ([ADR 0003](docs/adr/0003-secret-store-and-lab-ca-live-on-the-host.md)): generated once in `~/.local/share/k3d-lab/ca/` and never regenerated, then trusted by the Host, so `curl` and browsers trust every Lab URL across rebuilds. Name constraints limit it to `lab.localhost` (where every Lab UI lives), `k3d.internal`, the Lab's subnet and loopback.
- **The Secret Store** ([ADR 0003](docs/adr/0003-secret-store-and-lab-ca-live-on-the-host.md)): OpenBao, as the rootless Podman Quadlet `k3d-lab-secret-store` (a user service of yours, started at boot through lingering), with all its state in `~/.local/share/k3d-lab/secret-store/`. It unseals itself at every start, with OpenBao's `static` seal and a key generated once, and serves TLS from the Lab CA on port 8200. A firewalld policy lets only the Lab's subnet, `172.28.0.0/16`, reach that port, so it's closed to the LAN; the Secret Store only starts once that policy is in place. See [Secrets](docs/secrets.md).
- **The Lab login** ([ADR 0013](docs/adr/0013-single-sign-on-is-a-standalone-dex-with-the-lab-login-in-the-secret-store.md)): its password, and a secret for each OIDC client in `platform/dex/config.yaml`, generated once into the Secret Store under `lab/platform/sso/` and never changed. A client added there later gets its secret at the next run; Dex and the client then each need it from an ExternalSecret, as `platform/dex/dex.yaml` gives Dex the others. `just up` refuses to build a Lab while one is missing.

`just host setup` never escalates privileges. It goes through the steps in order, and when it reaches one that needs root, it stops and asks you to run the same script under sudo yourself, then `just host setup` again:

```sh
sudo scripts/host-setup.sh
```

`just host wizard` walks you through the steps only you can do: for now, reserving the Host's LAN address on your router, which the GPU Node needs. It saves the address to `.env`.

`just down` never touches any of this.

## Everyday commands

| Command | What it does |
|---|---|
| `just doctor` | Checks the Host has what the Lab needs: the tools, every `just host setup` step, that the Secret Store is running and unsealed, free space in Docker's data directory, and that `HOST_LAN_IP` in `.env` is still the Host's address. Installs nothing. |
| `just up` | Builds the Lab, and stops once every Application is Synced and Healthy. Refuses if a Lab already exists. ArgoCD builds it from the branch checked out here, as pushed, since `verify` runs the checks from this checkout; `just up REVISION=<branch>` picks another pushed branch or tag. It builds no Demos, such as the demo Rollout; `just up --demos` builds them too. `just up --debug` builds the Lab, Demos included, as a debugging run: below records the pressure throughout, and `just verify` runs at the end, which also reports a k3s restart on the Server during the build. That's the test of a change. A run without it says only if k3s restarted and, when it fails, whether the Host is short on memory, and suggests `--debug` for the next attempt. |
| `just track [<branch>]` | Points the running Lab at another pushed branch or tag, as `just up` would have built it, without rebuilding it: ArgoCD syncs the Platform and Workloads from it, and it stops once every Application is Synced and Healthy there. The Lab keeps the Demos it has, or none; `just demos` changes that. `just track [<branch>] --debug` also records the pressure and ends with `just verify`, as `just up --debug` does, but adds no Demos. By default, the branch checked out here; run it again after pushing to pick up new commits at once. Refuses a branch that isn't pushed, and refuses while any Workload or Platform component is paused. |
| `just demos on\|off` | Adds the Demos to the running Lab, or removes them with their namespaces, without rebuilding it. It stops once their Applications are Synced and Healthy, or gone. `just verify` skips a Demo's checks while the Lab has none, and says so. |
| `just pause <name>` | Pauses a Workload or Platform component, named as its folder, for an experiment that has no business in Git: ArgoCD neither syncs nor self-heals its Application, so changes made by hand to it stay. The other Applications still sync. `just verify` warns while any is paused. |
| `just resume <name>` | Lets ArgoCD sync a paused Workload or Platform component again, which puts Git back, and waits until it's Synced and Healthy. |
| `just creds` | Prints the Lab login, which opens every UI of the Platform and stays the same across Labs, then each UI with its URL and its Break-glass login, which is new with every Lab. |
| `just verify` | Checks how the running Lab behaves, with one Chainsaw test per check in `verify/`: a PASS or FAIL for each, and a non-zero exit on any FAIL. `just verify <check>...` runs only those checks, named by their folders; any Chainsaw flags go after them. `VERBOSE=1 just verify <check>` also shows what each passing step did, such as each OK line of the check's script, which is how to see what a new check really tests. While `just verify`, `just up --debug` or `just track --debug` runs, [below](https://github.com/facebookincubator/below) records the pressure on the Host and each cgroup in it every 2s into `~/.local/state/k3d-lab/below/`, keeping a week; when k3s on the Server logs slow SQL, dies or restarts, `verify` WARNs with the Server's cgroups and the Host's disk in the minute before. |
| `just down` | Destroys the Lab completely, and fails if anything is left behind. A Joined GPU Node leaves first, if it's reachable. |
| `just lint` | Static checks that need no Lab. CI runs it on every PR. |
| `just gpu ssh [<command>]` | Runs the command on the GPU Node, as the user the Host logs in as, or opens a shell there when given none. Standard input passes through, so `just gpu ssh 'cat > <path>' < <file>` copies a file; quote a command that has a redirect, or it applies on the Host. |
| `just secret-store bao <args>` | Runs the `bao` CLI against the Secret Store, as its root. |
| `just secret-store backup <path>` | Archives the Secret Store, to a new file in `<path>` if it's a directory. See [Secrets](docs/secrets.md#backup-and-restore). |

The recipes for one part of the Lab are grouped under its name, as `just host …`, `just secret-store …`, `just gpu …` and `just comfyui …`; `just` on its own lists them all.

The Lab's kube context is `k3d-lab`. `just up` adds it to your kubeconfig without switching to it.

## The Lab's UIs

Every UI is served by name at `https://<name>.lab.localhost`, and plain HTTP redirects to HTTPS. `*.lab.localhost` always resolves to the Host's loopback ([ADR 0003](docs/adr/0003-secret-store-and-lab-ca-live-on-the-host.md)), where k3d publishes ports 80 and 443 of the Server. There, Cilium's Gateway API implementation runs the Lab's one Gateway (`platform/gateway/`) on the Server's own network, with no LoadBalancer.

The Gateway's wildcard certificate comes from cert-manager, signed by the Lab CA: `just up` loads the CA into the Lab as the `lab-ca` ClusterIssuer. The Host already trusts the Lab CA, so every new Lab's certificate is trusted without importing anything.

| UI | URL |
|---|---|
| ArgoCD | https://argocd.lab.localhost |
| Grafana | https://grafana.lab.localhost |
| Argo Rollouts | https://rollouts.lab.localhost |
| Hubble | https://hubble.lab.localhost |
| ComfyUI (while the GPU Node is Joined) | https://comfyui.lab.localhost |

A component adds its UI with an HTTPRoute for its own `<name>.lab.localhost`, whose `parentRefs` is the `https` listener of the Gateway `lab` in the namespace `gateway`.

### Logging in

One login, the **Lab login**, opens ArgoCD, Grafana, the Rollouts dashboard and Hubble UI ([ADR 0013](docs/adr/0013-single-sign-on-is-a-standalone-dex-with-the-lab-login-in-the-secret-store.md)). It's `lab@lab.localhost`, with a password that `just host setup` generated once into the Secret Store, so it's the same in every Lab. `just creds` prints it. You type it once: Dex remembers the browser for a day.

ArgoCD and Grafana each keep a Break-glass login too, new with every Lab, for when Dex is down. ComfyUI has no login.

[Logging in](docs/logging-in.md) has how the sign-in works, with a diagram for each kind of UI, and how to reach a UI when Dex or oauth2-proxy is down.

## How the Lab works

Each part of the Lab has its own page in `docs/`:

| Page | What's in it |
|---|---|
| [Logging in](docs/logging-in.md) | Dex, oauth2-proxy and the Lab login, with a diagram of each sign-in. |
| [GitOps](docs/gitops.md) | How ArgoCD manages the Lab from Git, and how to add a component. |
| [Keeping versions current](docs/keeping-versions-current.md) | Renovate's PRs for every pinned version. |
| [Observability](docs/observability.md) | Metrics, logs and traces: Alloy, Prometheus, Loki, Tempo and Grafana. |
| [Networking](docs/networking.md) | Cilium, Hubble, and the network policy for a Workload. |
| [Admission policy](docs/admission-policy.md) | Kyverno's policies, and how to add one. |
| [Progressive delivery](docs/progressive-delivery.md) | Argo Rollouts' canaries, and the demo Rollout. |
| [Secrets](docs/secrets.md) | External Secrets Operator and the Secret Store, with its backup and restore. |
| [The GPU Node](docs/gpu-node.md) | Joining and leaving, GPU Workloads, and ComfyUI. |

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

# k3d-lab

A disposable Kubernetes Lab on one workstation: k3d with Cilium, managed through GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling. `CONTEXT.md` defines the Lab's vocabulary, and `docs/adr/` records why it's built this way.

## Prerequisites

- **Docker CE**, running as root ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)); `just host-setup` installs it. The Lab's recipes always use Docker CE's socket, whatever your `DOCKER_HOST` says.
- **[mise](https://mise.jdx.dev/installing-mise.html)**, activated in your shell. It installs every other tool (`k3d`, `kubectl`, `helm`, `just`, `yq`, `shellcheck`, `kubeconform`) at the versions pinned in `mise.toml`, the same ones CI uses. Once, in this repo:

  ```sh
  mise trust && mise install
  ```

  The Lab's recipes use those versions whatever else is on your `PATH`.

`just doctor` checks all of this and prints hints for anything missing.

## Preparing the Host

Once per Host, run:

```sh
just host-setup
```

It prepares what outlives any Lab and is safe to re-run: a run with nothing to do says so.

- **Docker CE** ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)): installed with its data in `/home/docker-data` (labelled for SELinux like `/var/lib/docker`), started at boot, and usable without sudo through the `docker` group. If `podman-docker` is installed, `dnf` refuses Docker CE until you remove it (`sudo dnf remove podman-docker`); Podman itself can stay.
- **The Lab CA** ([ADR 0003](docs/adr/0003-secret-store-and-lab-ca-live-on-the-host.md)): generated once in `~/.local/share/k3d-lab/ca/` and never regenerated, then trusted by the Host, so `curl` and browsers trust every Lab URL across rebuilds. Name constraints limit it to `lab.localhost` (where every Lab UI lives), `k3d.internal`, the Lab's subnet and loopback.

`host-setup` never escalates privileges. It checks the steps that need root and, if any are left, asks you to run them yourself, then run `just host-setup` again:

```sh
sudo scripts/host-setup-root.sh
```

`just host-wizard` walks you through the steps only you can do: for now, reserving the Host's LAN address on your router, which the GPU Node needs. It saves the address to `.env`.

`just down` never touches any of this.

## Everyday commands

| Command | What it does |
|---|---|
| `just doctor` | Checks the Host has what the Lab needs: the tools, every `host-setup` step, free space in Docker's data directory, and that `HOST_LAN_IP` in `.env` is still the Host's address. Installs nothing. |
| `just up` | Builds the Lab, then runs `just verify`. Refuses if a Lab already exists. `just up REVISION=<branch>` builds it from a pushed branch instead of `main`. |
| `just verify` | Checks how the running Lab behaves, with one Chainsaw test per check in `verify/`: a PASS or FAIL for each, and a non-zero exit on any FAIL. `just verify <check>...` runs only those checks, named by their folders; any Chainsaw flags go after them. |
| `just down` | Destroys the Lab completely, and fails if anything is left behind. |
| `just lint` | Static checks that need no Lab. CI runs it on every PR. |

The Lab's kube context is `k3d-lab`. `just up` adds it to your kubeconfig without switching to it.

## GitOps

`just up` installs Cilium and ArgoCD with Helm, then applies one root Application. From then on ArgoCD manages the whole Lab, Cilium and itself included, from `main` of this repo (or the `REVISION` you gave `up`). A change merged there is applied without running `up` again.

The root Application syncs two ApplicationSets from `gitops/`: **Platform**, one Application per folder in `platform/`, and **Workloads**, one per folder in `workloads/`. Adding a component means adding one folder, `<group>/<name>/`, holding:

- `component.yaml`: the upstream chart (`chart`, `repoURL`, a pinned `version`) and the `namespace` to install it in.
- `values.yaml`: the chart's values. For Cilium and ArgoCD, `just up` installs from the same file, so bootstrap and ArgoCD never disagree.

Every Application syncs automatically, with pruning and self-heal: a change made by hand with `kubectl` is undone. Applications sync in no particular order, Platform and Workloads alike. One that needs CRDs another component installs fails, and retries until they exist.

`just lint` renders every component with its pinned chart and values and validates the output with `kubeconform`.

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

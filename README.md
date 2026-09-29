# k3d-lab

A disposable Kubernetes Lab on one workstation: k3d with Cilium, managed through GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling. `CONTEXT.md` defines the Lab's vocabulary, and `docs/adr/` records why it's built this way.

## Prerequisites

- **Docker CE**, running as root, alongside any Podman setup ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)). The Lab's recipes always use Docker CE's socket, whatever your `DOCKER_HOST` says.
- `k3d` 5.9 or newer, `kubectl`, `helm` and `just`. `shellcheck` and `kubeconform` are only needed for `just lint`.

`just doctor` checks all of this and prints install hints for anything missing.

## Everyday commands

| Command | What it does |
|---|---|
| `just doctor` | Checks the Host has what the Lab needs. Installs nothing. |
| `just up` | Builds the Lab, then runs `just verify`. Refuses if a Lab already exists. `just up REVISION=<branch>` builds it from a pushed branch instead of `main`. |
| `just verify` | Checks how the running Lab behaves: one PASS/FAIL/WARN line per check, non-zero exit on any FAIL. |
| `just down` | Destroys the Lab completely, and fails if anything is left behind. |
| `just lint` | Static checks that need no Lab. CI runs it on every PR. |

The Lab's kube context is `k3d-lab`. `just up` adds it to your kubeconfig without switching to it.

## GitOps

`just up` installs Cilium and ArgoCD with Helm, then applies one root Application. From then on ArgoCD manages the whole Lab, Cilium and itself included, from `main` of this repo (or the `REVISION` you gave `up`). A change merged there is applied without running `up` again.

The root Application syncs two ApplicationSets from `gitops/`: **Platform**, one Application per folder in `platform/`, and **Workloads**, one per folder in `workloads/`, which `just up` creates once the whole Platform is Healthy. Adding a component means adding one folder, `<group>/<name>/`, holding:

- `component.yaml`: the upstream chart (`chart`, `repoURL`, a pinned `version`), the `namespace` to install it in, and its `wave`, from 0 to 9. Within a group, each wave syncs once every lower wave is Healthy, so CRDs and operators go in an earlier wave than anything that uses them.
- `values.yaml`: the chart's values. For Cilium and ArgoCD, `just up` installs from the same file, so bootstrap and ArgoCD never disagree.

`just lint` renders every component with its pinned chart and values and validates the output with `kubeconform`.

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

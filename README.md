# k3d-lab

A disposable Kubernetes Lab on one workstation: k3d with Cilium, managed through GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling. `CONTEXT.md` defines the Lab's vocabulary, and `docs/adr/` records why it's built this way.

## Prerequisites

- **Docker CE**, running as root, alongside any Podman setup ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)). The Lab's recipes always use Docker CE's socket, whatever your `DOCKER_HOST` says.
- `k3d` 5.9 or newer, `kubectl`, `helm` and `just`. `shellcheck` is only needed for `just lint`.

`just doctor` checks all of this and prints install hints for anything missing.

## Everyday commands

| Command | What it does |
|---|---|
| `just doctor` | Checks the Host has what the Lab needs. Installs nothing. |
| `just up` | Builds the Lab, then runs `just verify`. Refuses if a Lab already exists. |
| `just verify` | Checks how the running Lab behaves: one PASS/FAIL/WARN line per check, non-zero exit on any FAIL. |
| `just down` | Destroys the Lab completely, and fails if anything is left behind. |
| `just lint` | Static checks that need no Lab. CI runs it on every PR. |

The Lab's kube context is `k3d-lab`. `just up` adds it to your kubeconfig without switching to it.

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

# k3d-lab

A disposable Kubernetes Lab on one workstation: k3d with Cilium, managed through GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling. `CONTEXT.md` defines the Lab's vocabulary, and `docs/adr/` records why it's built this way.

## Prerequisites

- **Docker CE**, running as root ([ADR 0001](docs/adr/0001-docker-ce-runtime-alongside-podman.md)); `just host-setup` installs it. The Lab's recipes always use Docker CE's socket, whatever your `DOCKER_HOST` says.
- **[mise](https://mise.jdx.dev/installing-mise.html)**, activated in your shell. It installs every other tool (`k3d`, `kubectl`, `helm`, `just`, `yq`, `shellcheck`, `kubeconform`) at the versions pinned in `mise.toml`, the same ones CI uses. Once, in this repo:

  ```sh
  mise trust && mise install
  ```

  The Lab's recipes use those versions whatever else is on your `PATH`.

- **Ports 80 and 443 free on the Host**: the Lab serves its UIs on them, on loopback.

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
| `just up` | Builds the Lab, then runs `just verify`. Refuses if a Lab already exists. ArgoCD builds it from the branch checked out here, as pushed, since `verify` runs the checks from this checkout; `just up REVISION=<branch>` picks another pushed branch or tag. |
| `just creds` | Prints each of the Lab's UIs with its URL and login. The passwords are new with every Lab. |
| `just verify` | Checks how the running Lab behaves, with one Chainsaw test per check in `verify/`: a PASS or FAIL for each, and a non-zero exit on any FAIL. `just verify <check>...` runs only those checks, named by their folders; any Chainsaw flags go after them. |
| `just down` | Destroys the Lab completely, and fails if anything is left behind. |
| `just lint` | Static checks that need no Lab. CI runs it on every PR. |

The Lab's kube context is `k3d-lab`. `just up` adds it to your kubeconfig without switching to it.

## The Lab's UIs

Every UI is served by name at `https://<name>.lab.localhost`, and plain HTTP redirects to HTTPS. `*.lab.localhost` always resolves to the Host's loopback ([ADR 0003](docs/adr/0003-secret-store-and-lab-ca-live-on-the-host.md)), where k3d publishes ports 80 and 443 of the Server. There, Cilium's Gateway API implementation runs the Lab's one Gateway (`platform/gateway/`) on the Server's own network, with no LoadBalancer.

The Gateway's wildcard certificate comes from cert-manager, signed by the Lab CA: `just up` loads the CA into the Lab as the `lab-ca` ClusterIssuer. The Host already trusts the Lab CA, so every new Lab's certificate is trusted without importing anything.

| UI | URL |
|---|---|
| ArgoCD | https://argocd.lab.localhost |
| Grafana | https://grafana.lab.localhost |

`just creds` prints each UI's admin login. Grafana also lets anyone look without logging in.

A component adds its UI with an HTTPRoute for its own `<name>.lab.localhost`, whose `parentRefs` is the `https` listener of the Gateway `lab` in the namespace `gateway`.

## GitOps

`just up` installs Cilium and ArgoCD with Helm, then applies one root Application. From then on ArgoCD manages the whole Lab, Cilium and itself included, from the branch `up` built it from (or the `REVISION` you gave it). A change pushed there is applied without running `up` again.

The root Application syncs two ApplicationSets from `gitops/`: **Platform**, one Application per folder in `platform/`, and **Workloads**, one per folder in `workloads/`. Adding a component means adding one folder, `<group>/<name>/`, holding:

- `component.yaml`: the upstream chart (`chart`, `repoURL`, a pinned `version`) and the `namespace` to install it in.
- `values.yaml`: the chart's values. For Cilium and ArgoCD, `just up` installs from the same file, so bootstrap and ArgoCD never disagree.

A component with no upstream chart, such as the Lab's own Gateway, leaves `chart`, `repoURL` and `version` out of `component.yaml`, and holds a `kustomization.yaml` instead of `values.yaml`.

Every Application syncs automatically, with pruning and self-heal: a change made by hand with `kubectl` is undone. Applications sync in no particular order, Platform and Workloads alike. One that needs CRDs another component installs fails, and retries until they exist.

`just lint` renders every component with its pinned chart and values, or its kustomization, and validates the output with `kubeconform`.

## Metrics

Each component comes from its own upstream chart, never an umbrella chart, and all run in the namespace `monitoring`:

- **Alloy** (`platform/alloy/`) is the only collector: a DaemonSet whose pod on each node scrapes what runs there, the kubelet, cAdvisor and every ServiceMonitor or PodMonitor target, and remote-writes it all to Prometheus. Every series carries a `node` label.
- **Prometheus** (`platform/prometheus/`) runs only its server, scrapes nothing itself and accepts remote writes. It keeps 7 days on a 10 Gi volume.
- **kube-state-metrics** and **node-exporter** ship ServiceMonitors that Alloy picks up. node-exporter's `drm` collector reports the GPU Node's GPU. The Prometheus-operator CRDs (`platform/prometheus-operator-crds/`) are only the ServiceMonitor and PodMonitor CRDs; no operator runs.
- **Grafana** (`platform/grafana/`) has Prometheus and Loki as its datasources. Its admin password is new with every Lab: `just up` generates it into the Secret `grafana-admin`, never Git.

A chart that ships a ServiceMonitor or PodMonitor is scraped with no change to Alloy, as long as its targets are pods: a target with no pod behind it, such as the API server's endpoints, runs on no node, so no Alloy scrapes it. Alloy and node-exporter tolerate the GPU Node's taint, so its metrics start as soon as it joins.

Dashboards live in Git, in `platform/grafana-dashboards/`: one JSON file each, listed in its `kustomization.yaml`. Grafana loads them without any import. To add one, build it in Grafana, save its JSON (Export, with "Export for sharing externally" off) there with a fixed `uid`, and add the file to the `kustomization.yaml`. Grafana won't save changes to a dashboard from Git: change it by exporting it again over its file.

## Logs

Every pod's logs, on every node, can be searched in Grafana under Explore, with the Loki datasource.

- **Alloy** reads the logs of the pods on its own node from the node's `/var/log/pods` and pushes them to Loki. Each stream is labelled with its `namespace`, `pod`, `container` and `node`, so `{namespace="argocd"}` finds ArgoCD's logs. A Joined GPU Node's logs start as soon as it's Ready.
- **Loki** (`platform/loki/`) comes from the `grafana-community` chart; `grafana/loki` now serves only Enterprise Logs. It runs as one process, in Monolithic mode, and keeps 7 days of logs on a 10 Gi volume.

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

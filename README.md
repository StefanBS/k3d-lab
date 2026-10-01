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
| Argo Rollouts | https://rollouts.lab.localhost |

`just creds` prints each UI's admin login. Grafana also lets anyone look without logging in, and the Rollouts dashboard has no login at all.

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
- **Grafana** (`platform/grafana/`) has Prometheus, Loki and Tempo as its datasources. Its admin password is new with every Lab: `just up` generates it into the Secret `grafana-admin`, never Git.

A chart that ships a ServiceMonitor or PodMonitor is scraped with no change to Alloy, as long as its targets are pods: a target with no pod behind it, such as the API server's endpoints, runs on no node, so no Alloy scrapes it. Alloy and node-exporter tolerate the GPU Node's taint, so its metrics start as soon as it joins.

Dashboards live in Git, in `platform/grafana-dashboards/`: one JSON file each, listed in its `kustomization.yaml`. Grafana loads them without any import. To add one, build it in Grafana, save its JSON (Export, with "Export for sharing externally" off) there with a fixed `uid`, and add the file to the `kustomization.yaml`. Grafana won't save changes to a dashboard from Git: change it by exporting it again over its file.

## Logs

Every pod's logs, on every node, can be searched in Grafana under Explore, with the Loki datasource.

- **Alloy** reads the logs of the pods on its own node from the node's `/var/log/pods` and pushes them to Loki. Each stream is labelled with its `namespace`, `pod`, `container` and `node`, so `{namespace="argocd"}` finds ArgoCD's logs. A Joined GPU Node's logs start as soon as it's Ready.
- **Loki** (`platform/loki/`) comes from the `grafana-community` chart; `grafana/loki` now serves only Enterprise Logs. It runs as one process, in Monolithic mode, and keeps 7 days of logs on a 10 Gi volume.

## Traces

A Workload sends its traces over OTLP to `alloy.monitoring.svc`: port 4317 for gRPC, 4318 for HTTP. They can be searched in Grafana under Explore, with the Tempo datasource, and each span links to its logs and its metrics.

- **Alloy** receives traces only from the pods on its own node: the Service `alloy` routes each pod to the Alloy there. It tags every span with the `k8s.namespace.name` and `k8s.pod.name` of the pod that sent it, found by the pod's IP, and forwards it to Tempo.
- **Tempo** (`platform/tempo/`) comes from the `grafana-community` chart. It runs as one process and keeps 7 days of traces on a 5 Gi volume. Its metrics generator turns every trace into a service graph (`traces_service_graph_*`) and span metrics (`traces_spanmetrics_*`, per `service` and `span_name`), which it remote-writes to Prometheus.
- **Grafana** links a span to its pod's logs in Loki, through those two tags, and to its service's span metrics in Prometheus. Its service graph shows who calls whom.

## Progressive delivery

**Argo Rollouts** (`platform/argo-rollouts/`) releases Workloads by canary, and its dashboard at https://rollouts.lab.localhost shows every Rollout. Anyone on the Host can promote or abort a Rollout there. A canary's traffic is split for real, by weight, at the Lab's Gateway: Rollouts' Gateway API plugin sets the weights of the Rollout's HTTPRoute, which Cilium applies. ArgoCD ignores those weights, and only those, when it compares an HTTPRoute with Git.

The demo Rollout (`workloads/rollouts-demo/`) is podinfo, at https://rollouts-demo.lab.localhost. A small load generator sends it 5 requests per second through the Gateway. A canary goes through these steps:

1. 20% of the traffic goes to the new version, then the analysis runs.
2. 50%, then the analysis.
3. 80%, then the analysis.
4. 100%: the new version becomes the stable one.

The analysis (`error-rate`, in `analysis.yaml`) asks Prometheus what share of the new version's requests failed (a 4xx or 5xx) over the last minute, from podinfo's own metrics, which Alloy scrapes every 10s. It measures 3 times, 30s apart, after waiting 1 minute for samples. More than one measurement at 5% or above, or with no requests to measure, aborts the canary: all traffic goes back to the stable version, and the Rollout is Degraded until Git changes again.

To try it, push a change to the branch the Lab tracks, and watch the dashboard, or the page itself, which shows the version that answered:

- **A canary that completes:** change `newTag` in `workloads/rollouts-demo/kustomization.yaml`.
- **A canary that's rolled back:** also set `PODINFO_RANDOM_ERROR` to `"true"` in `rollout.yaml`, and about a fifth of the new version's requests fail. Revert both to make the Rollout Healthy again.

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

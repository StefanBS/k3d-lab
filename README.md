# k3d-lab

A disposable Kubernetes Lab on one workstation: k3d with Cilium, managed through GitOps, for experimenting with networking, progressive delivery, observability and GPU scheduling. `CONTEXT.md` defines the Lab's vocabulary, and `docs/adr/` records why it's built this way.

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
- **The Secret Store** ([ADR 0003](docs/adr/0003-secret-store-and-lab-ca-live-on-the-host.md)): OpenBao, as the rootless Podman Quadlet `k3d-lab-secret-store` (a user service of yours, started at boot through lingering), with all its state in `~/.local/share/k3d-lab/secret-store/`. It unseals itself at every start, with OpenBao's `static` seal and a key generated once, and serves TLS from the Lab CA on port 8200. A firewalld policy lets only the Lab's subnet, `172.28.0.0/16`, reach that port, so it's closed to the LAN; the Secret Store only starts once that policy is in place. See Secrets.

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
| `just up` | Builds the Lab, then runs `just verify`. Refuses if a Lab already exists. ArgoCD builds it from the branch checked out here, as pushed, since `verify` runs the checks from this checkout; `just up REVISION=<branch>` picks another pushed branch or tag. |
| `just creds` | Prints each of the Lab's UIs with its URL and login. The passwords are new with every Lab. |
| `just verify` | Checks how the running Lab behaves, with one Chainsaw test per check in `verify/`: a PASS or FAIL for each, and a non-zero exit on any FAIL. `just verify <check>...` runs only those checks, named by their folders; any Chainsaw flags go after them. |
| `just down` | Destroys the Lab completely, and fails if anything is left behind. A Joined GPU Node leaves first, if it's reachable. |
| `just lint` | Static checks that need no Lab. CI runs it on every PR. |
| `just secret-store bao <args>` | Runs the `bao` CLI against the Secret Store, as its root. |
| `just secret-store backup <path>` | Archives the Secret Store, to a new file in `<path>` if it's a directory. See Secrets. |

The recipes for one part of the Lab are grouped under its name, as `just host …`, `just secret-store …` and `just gpu …`; `just` on its own lists them all.

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

`just creds` prints each UI's admin login. Grafana also lets anyone look without logging in, and the Rollouts dashboard and Hubble UI have no login at all.

A component adds its UI with an HTTPRoute for its own `<name>.lab.localhost`, whose `parentRefs` is the `https` listener of the Gateway `lab` in the namespace `gateway`.

## GitOps

`just up` installs Cilium and ArgoCD with Helm, then applies one root Application. From then on ArgoCD manages the whole Lab, Cilium and itself included, from the branch `up` built it from (or the `REVISION` you gave it). A change pushed there is applied without running `up` again.

The root Application syncs two ApplicationSets from `gitops/`: **Platform**, one Application per folder in `platform/`, and **Workloads**, one per folder in `workloads/`. Adding a component means adding one folder, `<group>/<name>/`, holding:

- `component.yaml`: the upstream chart (`chart`, `repoURL`, a pinned `version`) and the `namespace` to install it in.
- `values.yaml`: the chart's values. For Cilium and ArgoCD, `just up` installs from the same file, so bootstrap and ArgoCD never disagree.

A component with no upstream chart, such as the Lab's own Gateway, leaves `chart`, `repoURL` and `version` out of `component.yaml`, and holds a `kustomization.yaml` instead of `values.yaml`.

Each ApplicationSet's Applications run in the ArgoCD project of the same name (`gitops/templates/appprojects.yaml`), and the root Application runs in `platform`. `platform` may install anything. `workloads` may only create namespaced resources, and not in a Platform namespace or Kubernetes' own: ArgoCD refuses the sync otherwise. Since the gitops chart can't read `component.yaml`, it lists the Platform's namespaces in `gitops/values.yaml`, and `just lint` fails until a new Platform namespace is added there. ArgoCD's `default` project allows nothing, so an Application that names no project fails rather than running unconfined.

The Platform also sets up each Workload's namespace: it's labelled `k3d-lab/group: workloads`, and `k3d-lab/isolation: strict` too if the Workload's `component.yaml` sets `isolation: strict`. A Workload never labels its own namespace. Unless it's `isolation: strict`, its Application also gets the baseline's same-namespace allow (see Network policy for a Workload).

Every Application syncs automatically, with pruning and self-heal: a change made by hand with `kubectl` is undone. There are two exceptions, in every Application, because Argo Rollouts sets them during a canary (see Progressive delivery): the backend weights of an HTTPRoute, and the `rollouts-pod-template-hash` key of a Service's selector. ArgoCD neither reports nor reverts them. Applications sync in no particular order, Platform and Workloads alike. One that needs CRDs another component installs fails, and retries until they exist.

`just lint` renders every component with its pinned chart and values, or its kustomization, and its Application as the ApplicationSet generates it, and validates the output with `kubeconform`.

## Keeping versions current

Renovate (`renovate.json5`) opens PRs for every pinned version that has a newer release: the charts in `component.yaml`, the k3s image, image tags, the tools in `mise.toml`, CI's actions and mise, GitHub release assets, and the Secret Store's image in `scripts/host.sh`. It groups related updates into one PR, such as Observability or GPU, and lists everything it tracks in its Dependency Dashboard issue. It never merges: every PR runs `just lint`, and waits for you.

A pin in a file Renovate can't read by itself, such as a script, gets a comment on the line above, like the Secret Store's image in `scripts/secret-store.sh`. It works in any `.sh` or YAML file and the Justfile:

```bash
# renovate: datasource=docker depName=<image>
SOME_IMAGE=<image>:<version>
```

Groups name their dependencies in `renovate.json5`, so a new component joins one, such as Observability, with a line there too; otherwise it gets PRs of its own.

Renovate is a GitHub app, so enabling it is a step you do yourself, once: install the [Renovate app](https://github.com/apps/renovate) on your account with access to this repo only. With `renovate.json5` already on `main`, it skips its onboarding PR and opens the Dependency Dashboard and the update PRs straight away.

Some updates need more than a merge: the Argo Rollouts Gateway API plugin needs its new `sha256`, and the Secret Store reaches the new image only when you re-run `just host setup`. Their PRs say so.

## Metrics

Each component comes from its own upstream chart, never an umbrella chart, and all run in the namespace `monitoring`:

- **Alloy** (`platform/alloy/`) is the only collector: a DaemonSet whose pod on each node scrapes what runs there, the kubelet, cAdvisor and every ServiceMonitor or PodMonitor target, and remote-writes it all to Prometheus. Every series carries a `node` label.
- **Prometheus** (`platform/prometheus/`) runs only its server, scrapes nothing itself and accepts remote writes. It keeps 7 days on a 10 Gi volume.
- **kube-state-metrics** and **node-exporter** ship ServiceMonitors that Alloy picks up. node-exporter's `drm` collector reports the GPU Node's GPU. The Prometheus-operator CRDs (`platform/prometheus-operator-crds/`) are only the ServiceMonitor and PodMonitor CRDs; no operator runs.
- **Grafana** (`platform/grafana/`) has Prometheus, Loki and Tempo as its datasources. Its admin password is new with every Lab: ESO generates it once into the Secret `grafana-admin` (a `Password` generator in its values), so it never goes in Git.

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

## Networking

Cilium is the Lab's network, and Hubble shows what travels over it. Hubble is part of Cilium (`platform/cilium/values.yaml`); `platform/hubble/` adds its UI's HTTPRoute and its ServiceMonitor.

- **Hubble UI**, at https://hubble.lab.localhost, shows every namespace's flows live, from Hubble Relay, which gathers them from the cilium-agent on every node, the GPU Node included while it's Joined.
- **Flow metrics**: every cilium-agent counts the flows it sees, forwarded and dropped, by namespace at both ends, and Alloy scrapes them like any other ServiceMonitor. The dashboard "Hubble network" shows drops by reason and by namespace. DNS and HTTP counts only cover the traffic that a network policy's DNS or HTTP rule sends through Cilium's proxies.

### Network policy for a Workload

Each Workload's namespace denies all traffic, in and out, except what a policy allows. The Platform writes most of that policy, in three tiers (ADR 0008):

- **The guardrails** (`platform/workload-network-policy/guardrails.yaml`): no Workload reaches the kube-apiserver or the cloud metadata address, whatever its own policy allows.
- **The baseline**, which every Workload gets without writing anything: DNS, through Cilium's DNS proxy; the Gateway to any port named `http`; Alloy to any port named `metrics`; and every pod in the namespace to every other. All but the last are cluster-wide policies in `platform/workload-network-policy/`, for every namespace labelled `k3d-lab/group: workloads`. The same-namespace allow is a `CiliumNetworkPolicy` named `same-namespace`, which the `workloads` ApplicationSet adds to the Workload's own namespace.
- **The Workload policy**, its own `network-policy.yaml`, only for what's its business: egress to the internet by FQDN, calls to another namespace, and L7 rules.

So a new Workload that names its ports `http` and `metrics` writes no policy until it calls the internet or another namespace. Naming the ports doesn't expose anything by itself: the Gateway only reaches a pod through an HTTPRoute, and Alloy through a PodMonitor or ServiceMonitor. The Platform's namespaces have no policies yet.

A Workload that sets `isolation: strict` in its `component.yaml` doesn't get the same-namespace allow: its pods only reach each other where its own policy says so.

A denied flow shows in Hubble UI, and in `hubble observe -n <namespace> --verdict DROPPED`, as `Policy denied`, or `Policy denied by denylist` for a guardrail. To find what a Workload needs, watch its flows in Hubble UI before writing its policy, then watch for drops after. Two things that Hubble shows and aren't obvious:

- The Gateway's Envoy has the `ingress` identity, so a rule for requests through the Gateway, such as an L7 one, says `fromEntities: [ingress]`.
- A pod calling a Workload through the Gateway, such as the demo's load generator, needs egress to the Workload's pods, not to the Gateway: Envoy checks the caller's policy against the backend, and answers 403 when it's denied. In the same namespace, the baseline already allows it.

## Progressive delivery

**Argo Rollouts** (`platform/argo-rollouts/`) releases Workloads by canary, and its dashboard at https://rollouts.lab.localhost shows every Rollout. Anyone on the Host can promote or abort a Rollout there. A canary's traffic is split for real, by weight, at the Lab's Gateway: Rollouts' Gateway API plugin sets the weights of the Rollout's HTTPRoute, which Cilium applies. ArgoCD leaves those weights alone, as it does the version that Rollouts adds to each of the Rollout's Services' selectors (see GitOps).

The demo Rollout (`workloads/rollouts-demo/`) is podinfo, at https://rollouts-demo.lab.localhost. A small load generator sends it 5 requests per second through the Gateway. A canary goes through these steps:

1. 20% of the traffic goes to the new version, then the analysis runs.
2. 50%, then the analysis.
3. 80%, then the analysis.
4. 100%: the new version becomes the stable one.

The analysis (`error-rate`, in `analysis.yaml`) asks Prometheus what share of the new version's requests failed (a 4xx or 5xx) over the last minute, from podinfo's own metrics, which Alloy scrapes every 10s. It measures 3 times, 30s apart, after waiting 1 minute for samples. More than one measurement at 5% or above, or with no requests to measure, aborts the canary: all traffic goes back to the stable version, and the Rollout is Degraded until Git changes again.

To try it, push a change to the branch the Lab tracks, and watch the dashboard, or the page itself, which shows the version that answered:

- **A canary that completes:** change `newTag` in `workloads/rollouts-demo/kustomization.yaml`.
- **A canary that's rolled back:** set `PODINFO_RANDOM_ERROR` to `"true"` in `rollout.yaml`, with or without a new tag. That alone is a new version, and about a fifth of its requests fail. Revert it to make the Rollout Healthy again.

## Secrets

Workloads get their secrets as Kubernetes Secrets from **External Secrets Operator** (`platform/external-secrets/`), which reads them from the Secret Store on the Host. Secrets never go in Git, and survive `just down`.

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
- **What's kept on the Host:** `~/.local/share/k3d-lab/secret-store/` holds OpenBao's Raft data, its unseal key, and `init.json` with the root token and recovery key. The unseal key sits next to the data, so encryption at rest is mostly for show. `just secret-store bao` uses the root token.

### Backup and restore

`just secret-store backup <path>` stops OpenBao for a few seconds, archives that whole directory, and starts it again. The archive can read every secret, so keep it somewhere safe.

To restore an archive, on this Host or a new one:

```sh
systemctl --user stop k3d-lab-secret-store
mv ~/.local/share/k3d-lab/secret-store ~/.local/share/k3d-lab/secret-store.old
tar -xzf <archive> -C ~/.local/share/k3d-lab
just host setup
```

`just host setup` starts OpenBao on the restored data, and renews its certificate if the Lab CA is a new one. Once it works, delete `secret-store.old`.

## The GPU Node

The GPU Node is a gaming PC on the LAN that the Lab borrows now and then ([ADR 0002](docs/adr/0002-gpu-node-joins-over-routed-docker-bridge.md)). It joins as a k3s Agent, labelled `k3d-lab/gpu=amd` and tainted `amd.com/gpu:NoSchedule`, so only GPU Workloads run there. The Host runs its side of each step over SSH as the `k3dlab` user, by sending it `scripts/gpu-node.sh` ([ADR 0005](docs/adr/0005-gpu-node-lifecycle-is-bash-over-ssh.md)).

Once, after `just host wizard` and filling in `GPU_NODE_IP` and `GPU_NODE_SSH` in `.env`, run `just gpu wizard`. It generates the Host's key, `~/.ssh/k3d-lab_ed25519`, prints the two commands that create the `k3dlab` user on the GPU Node, and then tests the login.

| Command | What it does |
|---|---|
| `just gpu join [eviction=20Gi]` | Lends the GPU Node to the Lab. If k3s is already installed for this Lab, it only starts the agent. If the install is from an earlier Lab, it cleans that up first, keeping its images unless k3s goes back a version. It also sets the route to the Lab's subnet through `HOST_LAN_IP`, a firewalld zone that lets Cilium's proxies work there, absolute eviction thresholds (`eviction=`), and the model directory `/var/lib/k3d-lab/models`, which every GPU Workload can write to. It reports whether GPU Workloads need `supplementalGroups` for the GPU's devices. It waits for the Platform to run there, not for GPU Workloads, which start in their own time. |
| `just gpu leave` | Takes the GPU back: it drains the node, stops the agent and its pods (freeing VRAM), removes Cilium's state from the GPU Node, and deletes the Node object. The install, the route and the firewalld zone stay, so the next join is quick. If the GPU Node is off, it only deletes the Node object, and the next `just gpu join` cleans the machine up. |
| `just gpu leave purge` | Also removes k3s, its images, its files, the route and the firewalld zone. Only the `k3dlab` user, its key and the model directory stay. |
| `just gpu status` | Shows the GPU Node's state in the Lab and on the machine, with anything left behind. |

The agent is never enabled at boot. After any reboot the GPU Node is Left, and the GPU is entirely yours until the next `just gpu join`. While it's Joined but powered off, `just verify` WARNs about it and skips its checks. The Platform's DaemonSets stop counting it while it's off, so every Application stays Healthy.

### GPU Workloads

A GPU Workload requests the GPU as `amd.com/gpu: 1` and tolerates the `amd.com/gpu:NoSchedule` taint. AMD's device plugin (`platform/amd-gpu/`) advertises the GPU, and its node labeller adds `amd.com/gpu.*` labels describing it. Both run only on the GPU Node. Nothing ROCm-related is installed on the GPU Node, so a GPU Workload's image brings ROCm. The GPU's devices are world-accessible there, so a GPU Workload can run as non-root without `supplementalGroups`; `just gpu join` warns if that changes.

There's one GPU, advertised as one `amd.com/gpu`, so only one GPU Workload runs at a time; another stays Pending until the GPU is free.

### ComfyUI

ComfyUI (`workloads/comfyui/`) generates and edits images with [Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1) on the GPU through ROCm, at https://comfyui.lab.localhost, and holds the GPU while the GPU Node is Joined. It runs text to image, editing with up to 10 reference images, and Alibaba PAI's Fun ControlNet Union, all measured at 1024×1024; ControlNet was tried with line art only. Start from the Qwen-Image-2.1 templates in its workflow browser; its API takes the same workflows, exported in API format, at `/prompt`. [The benchmarks](docs/benchmarks/qwen-image-2.1.md) compare it with stable-diffusion.cpp, which it replaced for being about 2.7 times as fast.

- **The weights** are Comfy-Org's int8 ConvRot denoiser, text encoder and ControlNet, and the BF16 VAE, 21 GB in all. Its first pod downloads them into `/var/lib/k3d-lab/models/comfyui/weights` on the GPU Node, each pinned to a commit and checked against its checksum, in a folder per model type so that each loader node lists only its own files.
- **The install** runs on `rocm/pytorch`, pinned by digest, which brings PyTorch and ROCm. A setup container installs ComfyUI at a pinned commit and the exact packages in `config/requirements.txt` into `/var/lib/k3d-lab/models/comfyui/runtime`, once: a later start with the same commit and lock reuses it.
- **What it saves**, your workflows and settings (`user/`) and its images (`output/`), stays in `/var/lib/k3d-lab/models/comfyui` too. Uploaded images last only as long as the pod.
- **`--reserve-vram 3`** keeps 3 GB of VRAM free. Without it, a 1024×1024 ControlNet job corrupts the VAE in ComfyUI's dynamic VRAM, and every later job comes out NaN until a restart. A NaN guard (`config/nan_guard.py`) fails any job whose denoiser or VAE produces NaN, rather than saving a black or noise image.
- **Memory:** it keeps the models it has loaded in RAM, up to 21.4 GiB, and its limit is 24 GiB, so an overrun stops ComfyUI rather than one of the GPU Node's own processes.

Every leave and purge keep `/var/lib/k3d-lab/models`, so the weights, the install and what it saved outlive the Lab. Its image, about 20 GB, outlives leaves and rebuilds of the Lab too; only a purge, or a join that takes k3s back a version, removes it. The model is under the Qwen Research License, for non-commercial use.

It's a DaemonSet on the GPU Node ([ADR 0006](docs/adr/0006-gpu-workloads-are-daemonsets-on-the-gpu-node.md)), so while the GPU Node is Left it has no pod at all, and its Application stays Healthy. `just verify` checks, while the GPU Node is Joined, that the GPU is advertised, and that ComfyUI answers through the Gateway, loaded the NaN guard and uses the RX 7800 XT.

## Machine-specific values

This repo is public, so values specific to your machines (LAN IPs, SSH destinations) go in an untracked `.env`. Copy `.env.example` to `.env` and fill it in. Only the GPU Node recipes need it.

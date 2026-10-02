# GPU Workloads are DaemonSets on the GPU Node, not Pending pods

The spec wanted GPU Workloads to wait as Pending while the GPU Node is Left or off, and resume by themselves when it's Joined again. A Pending pod turns its Application Degraded, though, so a Left GPU Node, which is the normal state after every reboot, would fail `just up` and `applications-synced-and-healthy`. So a long-running GPU Workload is a DaemonSet that selects the GPU Node by its `k3d-lab/gpu=amd` label and tolerates its taint. While the GPU Node is Left, the DaemonSet wants no pod at all, and ArgoCD calls it Healthy. When the GPU Node joins, its pod starts without anyone asking. With one GPU, an update stops the old pod before starting the new one, which is the DaemonSet's default.

Ollama is the first such Workload (`workloads/ollama/`). It holds the only `amd.com/gpu`, so the `rocminfo` smoke-test Job could never schedule while Ollama runs. The Job is gone, and two checks prove the GPU path instead: `gpu-advertised` (the GPU Node advertises `amd.com/gpu`) and `ollama` (ROCm finds gfx1101, and Ollama answers through the Gateway).

## Considered Options

- **A Deployment, with its Application allowed to be Degraded**: Pending is what the spec described, but `verify` would then have to tell a Left GPU Node from a broken Workload, and `just up` couldn't wait for a Healthy Lab.
- **A Deployment scaled to zero by `gpu-leave`**: ArgoCD's self-heal would scale it back, or the replica count would have to be ignored, which hides real drift.
- **Keeping the `rocminfo` Job** beside Ollama: it would sit Pending for as long as Ollama holds the GPU.

## Consequences

- A GPU Workload has a pod only while the GPU Node is Joined and Ready, so it's never Pending. A Joined GPU Node that's powered off leaves its pod unreachable, as with every other DaemonSet there (ADR 0002).
- A second GPU Workload would compete with Ollama for the one GPU. It would need Ollama removed from Git first, or a way to share the GPU that the Lab doesn't have.
- GPU Workloads assume the GPU Node's `/dev/kfd` and `/dev/dri` are world-accessible, as they are on Nobara, and run as non-root without `supplementalGroups`. The render group's GID belongs to the machine, and the manifests in a public repo can't carry it. `gpu-join` detects the permissions and warns when they're stricter, so a GPU Workload failing to open the GPU has an explanation.

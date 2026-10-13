# The GPU Node

The GPU Node is a gaming PC on the LAN that the Lab borrows now and then ([ADR 0002](adr/0002-gpu-node-joins-over-routed-docker-bridge.md)). It joins as a k3s Agent, labelled `k3d-lab/gpu=amd` and tainted `amd.com/gpu:NoSchedule`, so only GPU Workloads run there. The Host runs its side of each step over SSH as the `k3dlab` user, by sending it `scripts/gpu-node.sh` ([ADR 0005](adr/0005-gpu-node-lifecycle-is-bash-over-ssh.md)).

Once, after `just host wizard` and filling in `GPU_NODE_IP` and `GPU_NODE_SSH` in `.env`, run `just gpu wizard`. It generates the Host's key, `~/.ssh/k3d-lab_ed25519`, prints the two commands that create the `k3dlab` user on the GPU Node, and then tests the login.

| Command | What it does |
|---|---|
| `just gpu join [eviction=20Gi]` | Lends the GPU Node to the Lab. If k3s is already installed for this Lab, it only starts the agent. If the install is from an earlier Lab, it cleans that up first, keeping its images unless k3s goes back a version. It also sets the route to the Lab's subnet through `HOST_LAN_IP`, a firewalld zone that lets Cilium's proxies work there, absolute eviction thresholds (`eviction=`), and the model directory `/var/lib/k3d-lab/models`, which every GPU Workload can write to. It reports whether GPU Workloads need `supplementalGroups` for the GPU's devices. It waits for the Platform to run there, not for GPU Workloads, which start in their own time. |
| `just gpu leave` | Takes the GPU back: it drains the node, stops the agent and its pods (freeing VRAM), removes Cilium's state from the GPU Node, and deletes the Node object. The install, the route and the firewalld zone stay, so the next join is quick. If the GPU Node is off, it only deletes the Node object, and the next `just gpu join` cleans the machine up. |
| `just gpu leave purge` | Also removes k3s, its images, its files, the route and the firewalld zone. Only the `k3dlab` user, its key and the model directory stay. |
| `just gpu status` | Shows the GPU Node's state in the Lab and on the machine, with anything left behind. |

The agent is never enabled at boot. After any reboot the GPU Node is Left, and the GPU is entirely yours until the next `just gpu join`. While it's Joined but powered off, `just verify` WARNs about it and skips its checks. The Platform's DaemonSets stop counting it while it's off, so every Application stays Healthy.

## GPU Workloads

A GPU Workload requests the GPU as `amd.com/gpu: 1` and tolerates the `amd.com/gpu:NoSchedule` taint. AMD's device plugin (`platform/amd-gpu/`) advertises the GPU, and its node labeller adds `amd.com/gpu.*` labels describing it. Both run only on the GPU Node. Nothing ROCm-related is installed on the GPU Node, so a GPU Workload's image brings ROCm. The GPU's devices are world-accessible there, so a GPU Workload can run as non-root without `supplementalGroups`; `just gpu join` warns if that changes.

There's one GPU, advertised as one `amd.com/gpu`, so only one GPU Workload runs at a time; another stays Pending until the GPU is free.

## ComfyUI

ComfyUI (`workloads/comfyui/`) generates and edits images with [Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1) on the GPU through ROCm, at https://comfyui.lab.localhost, and holds the GPU while the GPU Node is Joined. It runs text to image, editing with up to 10 reference images, and Alibaba PAI's Fun ControlNet Union, all measured at 1024×1024; ControlNet was tried with line art only. Start from the Qwen-Image-2.1 templates in its workflow browser; its API takes the same workflows, exported in API format, at `/prompt`. [The benchmarks](benchmarks/qwen-image-2.1.md) compare it with stable-diffusion.cpp, which it replaced for being about 2.7 times as fast.

- **The weights** are Comfy-Org's int8 ConvRot denoiser, text encoder and ControlNet, and the BF16 VAE, 21 GB in all. Its first pod downloads them into `/var/lib/k3d-lab/models/comfyui/weights` on the GPU Node, each pinned to a commit and checked against its checksum, in a folder per model type so that each loader node lists only its own files.
- **The install** runs on `rocm/pytorch`, pinned by digest, which brings PyTorch and ROCm. A setup container installs ComfyUI at a pinned commit and the exact packages in `config/requirements.txt` into `/var/lib/k3d-lab/models/comfyui/runtime`, once: a later start with the same commit and lock reuses it. Renovate proposes new commits but never touches the lock: `just comfyui lock` regenerates it for the commit in `config/setup.sh`, in ComfyUI's image on the Joined GPU Node, and fails unless `pip check` passes.
- **What it saves**, your workflows and settings (`user/`) and its images (`output/`), stays in `/var/lib/k3d-lab/models/comfyui` too. Uploaded images last only as long as the pod.
- **`--reserve-vram 3`** keeps 3 GB of VRAM free. Without it, a 1024×1024 ControlNet job corrupts the VAE in ComfyUI's dynamic VRAM, and every later job comes out NaN until a restart. A NaN guard (`config/nan_guard.py`) fails any job whose denoiser or VAE produces NaN, rather than saving a black or noise image.
- **Memory:** it keeps the models it has loaded in RAM, up to 21.4 GiB, and its limit is 24 GiB, so an overrun stops ComfyUI rather than one of the GPU Node's own processes.

Every leave and purge keep `/var/lib/k3d-lab/models`, so the weights, the install and what it saved outlive the Lab. Its image, about 20 GB, outlives leaves and rebuilds of the Lab too; only a purge, or a join that takes k3s back a version, removes it. The model is under the Qwen Research License, for non-commercial use.

It's a DaemonSet on the GPU Node ([ADR 0006](adr/0006-gpu-workloads-are-daemonsets-on-the-gpu-node.md)), so while the GPU Node is Left it has no pod at all, and its Application stays Healthy. `just verify` checks, while the GPU Node is Joined, that the GPU is advertised, and that ComfyUI answers through the Gateway, loaded the NaN guard and uses the RX 7800 XT.

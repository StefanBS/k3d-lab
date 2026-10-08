# ComfyUI installs from a lock on the GPU Node, not from an image of the Lab's

ComfyUI replaced stable-diffusion.cpp's sd-server for Qwen-Image-2.1: it sampled about 2.7 times as fast on the RX 7800 XT, and it runs the Fun ControlNet Union, which sd.cpp has no support for (`docs/benchmarks/qwen-image-2.1.md`). Neither ComfyUI nor anyone the Lab trusts publishes an image of it for ROCm, so the Workload (`workloads/comfyui/`) runs AMD's `rocm/pytorch`, pinned by digest, and a setup container installs ComfyUI into a venv on the GPU Node: at a commit pinned in `config/setup.sh`, with the exact packages in `config/requirements.txt`, and with `--no-deps`, so nothing it installs replaces the image's PyTorch. It installs once per commit and lock, and later starts reuse the install.

## Considered Options

- **An image of the Lab's, built by CI from `rocm/pytorch`**: immutable, but `rocm/pytorch` is 19.6 GB compressed, more than a standard GitHub runner has room to build from, and every build would push about as much to a registry the Lab would then own.
- **A community image**, such as `yanwk/comfyui-boot`: installs ComfyUI and its custom nodes at its first start anyway, runs as root, and isn't pinned by anything the Lab controls.
- **Installing at every start**, into an `emptyDir`: a fresh install from PyPI with every pod, which then fails whenever PyPI or GitHub is unreachable.

## Consequences

- What runs is still all in Git: the image digest, the ComfyUI commit and every package version. Renovate updates the digest and the commit together, once a week, but never the lock's packages: bumped one by one, their pins broke each other, and only the setup container's `pip check` caught it, on the GPU Node, after merging.
- A new ComfyUI commit needs the lock regenerated before merging, with `just comfyui lock` on the Joined GPU Node. It installs the current lock with `--no-deps` in ComfyUI's image, then ComfyUI's `requirements.txt` at that commit over it, runs `pip check` and writes the venv's `pip freeze`. So a package moves only when ComfyUI needs it to, and one that ComfyUI stops needing stays until it's removed by hand. The image runs in the agent's containerd, outside the Lab, so its downloads aren't bound by ComfyUI's network policy.
- The install lives in `/var/lib/k3d-lab/models/comfyui/runtime`, beside the weights, so it survives every leave, purge and rebuild of the Lab, as they do. A change to the commit or the lock reinstalls it, from GitHub and PyPI.
- The GPU Node's disk holds the image, about 20 GB compressed, and 21 GB of weights. The image survives leaves and the cleanup of a Stale install, so a rebuilt Lab doesn't pull it again. Only `just gpu leave purge`, or a join that takes k3s back a version, removes it, and the next join pulls it again.

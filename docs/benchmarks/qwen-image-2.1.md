# Qwen-Image-2.1 on the GPU Node

How fast each runtime generates with Qwen-Image-2.1 on the GPU Node's RX 7800 XT (16 GB, gfx1101), with 31 GB of RAM. Timings come from each runtime's own log. The prompts weren't recorded: sd-server doesn't log them.

## stable-diffusion.cpp `sd-server`, Vulkan

2026-10-02, `workloads/qwen-image/` as of #48: sd.cpp `master-vulkan@sha256:5a13accc…` (commit `3f8527a`), Mesa RADV.

- **Weights:** denoiser GGUF Q8_0 (`leejet/Qwen-Image-2.1-GGUF`), Qwen3-VL-8B-Instruct Q4_K_M with its F16 mmproj, BF16 VAE. 13.4 GB in RAM, none resident in VRAM (`--offload-to-cpu`).
- **Flags:** `--diffusion-fa`, prefix cache at its default (`auto`). Every request was 1024×1024, CFG 6, Euler (Flux schedule), seed 42.

| Request | Steps | Text encoding | Sampling | Per step | VAE decode | Total |
|---|---:|---:|---:|---:|---:|---:|
| Text to image | 20 | 5.6 s | 162.9 s | 7.8 s | 14.9 s | 183.4 s |
| Edit, 1 reference (335×597) | 20 | 9.8 s | 510.1 s | 25.7 s | 13.7 s | 534.8 s |
| Edit, 1 reference + control image | – | – | – | – | – | crashed (SIGFPE) |
| Edit, 2 references (887×883, 335×597) | 20 | 17.0 s | 279.9 s | 12.8 s | 14.7 s | 314.0 s |
| Text to image | 50 | 4.3 s | 395.1 s | 7.8 s | 14.0 s | 413.4 s |

- **Per step** is sd.cpp's average over the run. The very first step after the server started took 13.9 s, while Vulkan built its pipelines.
- **Weight transfers** from RAM to VRAM took 0.2–1.6 s per stage, a small share of each request.
- **The edit with one reference** ran at twice the per-step time of the edit with two, which carry more tokens. The log doesn't say why.
- **The control image** isn't supported for Qwen-Image-2.1 in sd.cpp, which only has ControlNets for SD 1.x, 2.x and SDXL. The server crashed (exit 136) instead of rejecting the request, and restarted.
- **VAE decode** logged `Failed to allocate pinned memory (… ErrorOutOfDeviceMemory)` and went on to finish.

Roughly, one pass of the 7B denoiser over about 4,300 tokens is 60 TFLOP, and CFG runs two per step: at 7.8 s per step, that's about 15 TFLOPS, against the card's rated 74 TFLOPS of FP16.

## ComfyUI, ROCm

2026-10-02, a one-off pod, then the Workload: ComfyUI `2472a20` on `rocm/pytorch:rocm7.14.1_ubuntu24.04_py3.12_pytorch_release_2.12.0` (PyTorch 2.12.0, HIP 7.14), PyTorch attention. ROCm found the card as gfx1101, and ComfyUI ran the int8 weights natively (`int8_tensorwise`).

- **Weights:** Comfy-Org's `qwen_image_2.1_int8_convrot` denoiser and `qwen3vl_8b_int8_convrot` text encoder, the same BF16 VAE, and `qwen_image_2.1_fun_controlnet_union_int8_convrot`. ComfyUI loads them into VRAM as each stage needs them.
- **Workflow:** as ComfyUI's templates, with `QwenImage21Cache` (its prefix cache), Euler, the simple scheduler, seed 42. The first request after start loads every model, so its total includes that.

| Request | Steps | CFG | Output | Sampling | Per step | Total | Image |
|---|---:|---:|---|---:|---:|---:|---|
| Text to image, first request | 20 | 6 | 1024×1024 | 57 s | 2.88 s | 92.2 s | good |
| Text to image | 50 | 6 | 1024×1024 | 144 s | 2.89 s | 145.9 s | good |
| Edit, 1 reference (335×597) | 20 | 1 | 768×1376 | 34 s | 1.71 s | 103.1 s | good |
| Edit, 1 reference (335×597) | 20 | 6 | 768×1376 | 78 s | 3.93 s | 80.1 s | good |
| ControlNet union, line art, plain model | 20 | 1 | 1024×1024 | 45 s | 2.26 s | 72.8 s | good, with `--reserve-vram 3` |

- **An edit** samples at the reference's aspect ratio, about the same pixel count as 1024×1024, when the latent comes from `TextEncodeQwenImage21`. Starting it from an empty 1024×1024 latent gave noise.
- **ControlNet** at strength 1 on every step follows the line art closely. Its last row is from the Workload, through the Gateway.

### NaN after a ControlNet job

With ComfyUI's defaults, the first 1024×1024 ControlNet job after a start comes out right, and every job after it, ControlNet or not, comes out NaN, as noise or a black image, until ComfyUI restarts. Every denoising step stays finite; the NaN comes from the VAE, in its encode of the next control or reference image or in its decode. A VAE-only round trip in the same process stays clean, so the VAE breaks only alongside the other models, in dynamic VRAM (comfy-aimdo), under the memory pressure of a 1024×1024 ControlNet job. 512×512 jobs never set it off.

These didn't change it: the bf16 ControlNet instead of the int8 one, the plain model instead of the prefix-cached one, control on the first 30% of steps only, strength 0.01, Comfy Kitchen attention, and fp32 compute (19 s per step).

Each option below ran the same sequence after a restart, at 1024×1024, 8 steps, CFG 1, with a guard that fails a job at its first NaN:

| Flags | ControlNet, text to image, ControlNet, edit, ControlNet, ControlNet | ControlNet per step | ControlNet job |
|---|---|---:|---:|
| none | ok, then NaN for all five | 2.24 s | 34 s |
| `--reserve-vram 3` | all ok | 2.23 s | 19–37 s |
| `--vram-headroom 3` | all ok | 2.23 s | 20–34 s |
| `--disable-smart-memory` | all ok | 2.23 s | 23–32 s: it reloads models each job |
| `--disable-dynamic-vram --disable-smart-memory` | ok, ok, then killed by the GPU Node's kernel, out of RAM at 28.3 GB | 3.81 s | 80 s |
| `--disable-dynamic-vram --lowvram` | the first job never finished | – | – |

Every image that came out right is identical, pixel for pixel, to the same job's under any other option: the flags change only where the models live. The Workload runs with `--reserve-vram 3`, which also keeps VRAM for the GPU Node's desktop, and keeps the guard. With every model loaded, ComfyUI holds 21.4 GiB of RAM, so its pod is limited to 24 GiB, which costs nothing in speed.

## Comparison

At the same settings, 1024×1024, 20 steps and CFG 6, ComfyUI sampled at 2.88 s per step against sd-server's 7.8, 2.7 times as fast, and an edit at 3.93 s per step against 12.8–25.7. Its int8 weights aren't sd-server's Q8_0 GGUF, so the weights aren't identical, though both are 8-bit.

#!/bin/sh
# Downloads each weight file once into /models/comfyui/weights on the GPU Node, about 21 GB
# in all, resuming a download the last pod didn't finish, and keeps it only if its
# checksum matches. Each is Comfy-Org's ComfyUI build, pinned to a commit of its repo, and
# goes in a folder named for its model type, as in that repo, so each of ComfyUI's loaders
# lists only its own files.
set -eu

revision=cb504a4090723e43f17ad01cec0359490e2de613
mkdir -p /models/comfyui/weights
cd /models/comfyui/weights

fetch() {
  file=$2/$1
  [ -f "$file" ] && return
  mkdir -p "$2"
  echo "Downloading $file"
  curl -fsSL --retry 5 -C - -o "$file.part" "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/$revision/$file"
  echo "$3  $file.part" | sha256sum -c -
  mv "$file.part" "$file"
}

# The denoiser and the Qwen3-VL text encoder, in ComfyUI's int8 ConvRot format, which it
# runs natively on ROCm.
fetch qwen_image_2.1_int8_convrot.safetensors diffusion_models \
  cb74113cb03faecd79611b01fd7fd642f0aa60d6f0b95086abee214d75eaa57d
fetch qwen3vl_8b_int8_convrot.safetensors text_encoders \
  8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f
fetch qwen_image_2.1_vae_bf16.safetensors vae \
  bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9
# Alibaba PAI's Fun ControlNet Union, which ComfyUI loads as a model patch.
fetch qwen_image_2.1_fun_controlnet_union_int8_convrot.safetensors model_patches \
  07aa961570ac0e03d4ca936aecd76854d077a33cde69b5092399afba01b3715d
echo "Weights ready"

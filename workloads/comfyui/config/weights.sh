#!/bin/sh
# Downloads each weight file once into /models/comfyui/weights on the GPU Node, about 22 GB
# in all, resuming a download the last pod didn't finish, and keeps it only if its
# checksum matches. Each is pinned to a commit of its repo. Qwen-Image-2.1's are Comfy-Org's
# ComfyUI build, and go in a folder named for their model type, as in that repo, so each of
# ComfyUI's loaders lists only its own files.
set -eu

mkdir -p /models/comfyui/weights
cd /models/comfyui/weights

# fetch <url> <file> <sha256>
fetch() {
  [ -f "$2" ] && return
  mkdir -p "${2%/*}"
  echo "Downloading $2"
  curl -fsSL --retry 5 -C - -o "$2.part" "$1"
  echo "$3  $2.part" | sha256sum -c -
  mv "$2.part" "$2"
}

# qwen <file> <folder> <sha256>
qwen() {
  fetch "https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/cb504a4090723e43f17ad01cec0359490e2de613/$2/$1" "$2/$1" "$3"
}

# The denoiser and the Qwen3-VL text encoder, in ComfyUI's int8 ConvRot format, which it
# runs natively on ROCm.
qwen qwen_image_2.1_int8_convrot.safetensors diffusion_models \
  cb74113cb03faecd79611b01fd7fd642f0aa60d6f0b95086abee214d75eaa57d
qwen qwen3vl_8b_int8_convrot.safetensors text_encoders \
  8bfd0f6e12abf2d2d697ecc888e5e90b0d6741d6708f05799f53afa560452e8f
qwen qwen_image_2.1_vae_bf16.safetensors vae \
  bb21f7473051e1ac368515dd3f2e15cd44d7a11748ee8823e1ddca3e4876b7c9
# Alibaba PAI's Fun ControlNet Union, which ComfyUI loads as a model patch.
qwen qwen_image_2.1_fun_controlnet_union_int8_convrot.safetensors model_patches \
  07aa961570ac0e03d4ca936aecd76854d077a33cde69b5092399afba01b3715d

# birefnet <file> <sha256>
birefnet() {
  fetch "https://huggingface.co/1038lab/BiRefNet/resolve/4d000788a9698c7f8d67c8c6ce2b40c768f5b909/$1" "RMBG/BiRefNet/$1" "$2"
}

# BiRefNet ToonOut, for ComfyUI-RMBG's background removal node, which loads a model from its
# Python source beside its weights. The node rewrites birefnet.py's one relative import when
# it loads it, so that file matches its checksum only until then.
birefnet birefnet.py a9566611aa07a6fbb68ddb6ac8e19e62c879a428fbfc2f44efa53d233f2e302f
birefnet BiRefNet_config.py e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52
birefnet config.json 966a1f0165b072d2d1309756e71907750e535ba5c3790d8cd0e69713ff3a56cd
birefnet BiRefNet_toonout.safetensors \
  5ff451d2e1d15dd22a66efea05640f79e470467f89f8bdc239a81a6757f66093
echo "Weights ready"

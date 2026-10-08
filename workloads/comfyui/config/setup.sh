#!/usr/bin/env bash
# Installs ComfyUI and the Python packages in requirements.txt into /models/comfyui/runtime
# on the GPU Node, beside the image's ROCm PyTorch, which pip never replaces. It installs
# once per ComfyUI commit and lock: later starts find the stamp and reuse the install.
set -euo pipefail

# renovate: datasource=git-refs depName=https://github.com/Comfy-Org/ComfyUI branch=master
COMFYUI_COMMIT=5c460d8172fe30761ff67c0df3d5643bb74e0d70

# rocprofiler-sdk with the HSA signal pool fix (ADR 0011), and ROCr with upstream's
# event-age fix (ADR 0012), which the DaemonSet mounts over the image's copies. They're
# built for the image's ROCm 7.14.1 and no other.
ROCPROFILER_SDK_URL=https://github.com/StefanBS/rocm-systems/releases/download/lab-rocprofiler-sdk-7.14.1-1/librocprofiler-sdk.so.1
ROCPROFILER_SDK_SHA256=95306a759732e075d7dd57f2bc1fd75e5d1d9d4866370240cdea72227e360ba4
ROCR_URL=https://github.com/StefanBS/rocm-systems/releases/download/lab-rocr-runtime-7.14.1-1/libhsa-runtime64.so.1
ROCR_SHA256=b3355b883f7578f9b6b5977c58e28b6e5ec8ad39894db779bf19069444a1b901

# Downloads $1 to $3 unless it's there already, checked against the sha256 $2.
fetch() {
  local url=$1 sha=$2 dest=$3
  echo "$sha  $dest" | sha256sum -c --status 2>/dev/null && return
  echo "Downloading ${dest##*/}"
  mkdir -p "${dest%/*}"
  curl -fsSL --retry 5 -o "$dest.part" "$url"
  echo "$sha  $dest.part" | sha256sum -c -
  mv "$dest.part" "$dest"
}
fetch "$ROCPROFILER_SDK_URL" "$ROCPROFILER_SDK_SHA256" /models/comfyui/rocm/librocprofiler-sdk.so.1
fetch "$ROCR_URL" "$ROCR_SHA256" /models/comfyui/rocm/libhsa-runtime64.so.1

runtime=/models/comfyui/runtime
stamp=$(cat /config/requirements.txt - <<<"$COMFYUI_COMMIT" | sha256sum | cut -d' ' -f1)
if [[ $(cat "$runtime/stamp" 2>/dev/null) == "$stamp" ]]; then
  echo "ComfyUI $COMFYUI_COMMIT is installed"
  exit 0
fi

# A venv can't be moved once made, so this installs in place, and writes the stamp last:
# an install that didn't finish has none, and is redone.
echo "Installing ComfyUI $COMFYUI_COMMIT"
rm -rf "$runtime"
mkdir -p "$runtime"
cd "$runtime"
python - "$COMFYUI_COMMIT" <<'EOF'
import io, sys, tarfile, urllib.request
url = f"https://github.com/Comfy-Org/ComfyUI/archive/{sys.argv[1]}.tar.gz"
tarfile.open(fileobj=io.BytesIO(urllib.request.urlopen(url).read())).extractall(".", filter="data")
EOF
mv "ComfyUI-$COMFYUI_COMMIT" ComfyUI

# A venv of its own, which sees the image's ROCm PyTorch in /opt/venv through a .pth file:
# --system-site-packages would reach the base Python's packages instead.
python -m venv venv
echo /opt/venv/lib/python3.12/site-packages > venv/lib/python3.12/site-packages/rocm-torch.pth
venv/bin/pip install --quiet --no-cache-dir --no-deps -r /config/requirements.txt
venv/bin/pip check

echo "$stamp" > stamp
echo "Installed ComfyUI $COMFYUI_COMMIT"

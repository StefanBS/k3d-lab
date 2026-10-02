#!/usr/bin/env bash
# Installs ComfyUI and the Python packages in requirements.txt into /models/comfyui/runtime
# on the GPU Node, beside the image's ROCm PyTorch, which pip never replaces. It installs
# once per ComfyUI commit and lock: later starts find the stamp and reuse the install.
set -euo pipefail

# renovate: datasource=git-refs depName=https://github.com/Comfy-Org/ComfyUI branch=master
COMFYUI_COMMIT=2472a20bd291451acc303917059ab14dfc380478

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

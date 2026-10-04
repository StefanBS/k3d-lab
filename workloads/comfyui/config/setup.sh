#!/usr/bin/env bash
# Installs ComfyUI, ComfyUI-RMBG's BiRefNet node and the Python packages in requirements.txt
# into /models/comfyui/runtime on the GPU Node, beside the image's ROCm PyTorch, which pip
# never replaces. It installs once per pair of commits and lock: later starts find the
# stamp and reuse the install.
set -euo pipefail

# renovate: datasource=git-refs depName=https://github.com/Comfy-Org/ComfyUI branch=master
COMFYUI_COMMIT=2472a20bd291451acc303917059ab14dfc380478
# renovate: datasource=git-refs depName=https://github.com/1038lab/ComfyUI-RMBG branch=main
COMFYUI_RMBG_COMMIT=229529e0ea63fb7085848225d74f91f6dc164956

runtime=/models/comfyui/runtime
stamp=$(cat /config/requirements.txt - <<<"$COMFYUI_COMMIT $COMFYUI_RMBG_COMMIT" | sha256sum | cut -d' ' -f1)
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
# extract <owner/repo> <commit>: GitHub's archive of it, into <repo>-<commit>.
extract() {
  python - "https://github.com/$1/archive/$2.tar.gz" <<'EOF'
import io, sys, tarfile, urllib.request
tarfile.open(fileobj=io.BytesIO(urllib.request.urlopen(sys.argv[1]).read())).extractall(".", filter="data")
EOF
}
extract Comfy-Org/ComfyUI "$COMFYUI_COMMIT"
mv "ComfyUI-$COMFYUI_COMMIT" ComfyUI

# Only ComfyUI-RMBG's BiRefNet node, the helpers it imports and the pack's widgets: the
# pack loads every module it has, and one that fails to import fails them all, while the
# others need SAM, GroundingDINO, ONNX Runtime and more.
extract 1038lab/ComfyUI-RMBG "$COMFYUI_RMBG_COMMIT"
src=ComfyUI-RMBG-$COMFYUI_RMBG_COMMIT
rmbg=ComfyUI/custom_nodes/ComfyUI-RMBG
mkdir -p "$rmbg/py"
mv "$src"/{__init__.py,LICENSE,web} "$rmbg"
mv "$src"/py/{AILab_BiRefNet.py,AILab_utils.py} "$rmbg/py"
rm -r "$src"
# It looks for its weights in ComfyUI's own models/RMBG, not through
# extra_model_paths.yaml, so that's a link to where weights.sh puts them.
ln -s /models/comfyui/weights/RMBG ComfyUI/models/RMBG

# A venv of its own, which sees the image's ROCm PyTorch in /opt/venv through a .pth file:
# --system-site-packages would reach the base Python's packages instead.
python -m venv venv
echo /opt/venv/lib/python3.12/site-packages > venv/lib/python3.12/site-packages/rocm-torch.pth
venv/bin/pip install --quiet --no-cache-dir --no-deps -r /config/requirements.txt
venv/bin/pip check

echo "$stamp" > stamp
echo "Installed ComfyUI $COMFYUI_COMMIT and ComfyUI-RMBG $COMFYUI_RMBG_COMMIT"

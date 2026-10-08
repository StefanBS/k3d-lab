#!/usr/bin/env bash
# The image's half of `just comfyui lock` (scripts/comfyui-lock.sh, ADR 0007). Runs
# inside ComfyUI's ROCm PyTorch image on the GPU Node, never on the Host: the Host sends
# it over stdin after scripts/gpu-node.sh, whose run subcommand starts the image, and
# the current lock after it.
#   bash -s -- <ComfyUI commit> <the current lock's line count>
# Installs the current lock with --no-deps, as setup.sh does, then ComfyUI's own
# requirements.txt at that commit over it, which changes only what that commit needs
# changed, and checks the result with pip check. Prints the new lock's packages, as pip
# freeze does; everything else goes to stderr.
set -euo pipefail

log() { printf '==> %s\n' "$*" >&2; }

main() {
  local commit=$1 lines=$2 work pip
  work=$(mktemp -d)
  cd "$work"
  # The rest of stdin, counted, so this never waits on the end of a pipe.
  head -n "$lines" >lock.txt
  curl -fsSL --retry 5 -o requirements.txt \
    "https://raw.githubusercontent.com/Comfy-Org/ComfyUI/$commit/requirements.txt"

  # The same venv as setup.sh's, which sees the image's ROCm PyTorch through a .pth
  # file, so pip counts PyTorch as installed and never replaces it.
  python -m venv venv
  echo /opt/venv/lib/python3.12/site-packages >venv/lib/python3.12/site-packages/rocm-torch.pth
  pip=(venv/bin/pip --quiet --disable-pip-version-check)
  log "Installing the current lock"
  "${pip[@]}" install --root-user-action=ignore --no-cache-dir --no-deps -r lock.txt >&2
  log "Installing ComfyUI $commit's requirements.txt over it"
  "${pip[@]}" install --root-user-action=ignore --no-cache-dir -r requirements.txt >&2
  "${pip[@]}" check >&2
  # Only the venv's own packages: the image's are pinned by its digest.
  "${pip[@]}" freeze --path venv/lib/python3.12/site-packages
}

# On one line, so that bash, reading this script from stdin, never reads past it: what
# follows on stdin is the current lock.
main "$@"; exit

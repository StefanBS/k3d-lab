#!/usr/bin/env bash
# Regenerates ComfyUI's lock, workloads/comfyui/config/requirements.txt (ADR 0007), for
# the ComfyUI commit in config/setup.sh, in ComfyUI's own image on the GPU Node, which
# must be Joined. comfyui-lock-image.sh does the work there; this keeps the lock's
# header and writes its packages.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

COMFYUI=$LAB_ROOT/workloads/comfyui
LOCK=$COMFYUI/config/requirements.txt

need_env GPU_NODE_SSH
gpu_node_reachable ||
  die "can't log in to the GPU Node as $GPU_NODE_SSH with sudo; is it on, and Joined ('just gpu join')?"

commit=$(sed -n 's/^COMFYUI_COMMIT=\([0-9a-f]\{40\}\)$/\1/p' "$COMFYUI/config/setup.sh")
[[ -n $commit ]] || die "can't read COMFYUI_COMMIT from $COMFYUI/config/setup.sh"
# By digest, as the kubelet pulled it, whatever the tag.
image=$(yq -e '.images[] | select(.name == "docker.io/rocm/pytorch") | .name + "@" + .digest' \
  "$COMFYUI/kustomization.yaml") || die "can't read rocm/pytorch's digest from $COMFYUI/kustomization.yaml"

log "Locking ComfyUI $commit's packages in $image on the GPU Node"
packages=$(
  cat "$LAB_ROOT/scripts/gpu-node.sh" "$LAB_ROOT/scripts/comfyui-lock-image.sh" "$LOCK" |
    gpu_ssh "sudo bash -s -- run $(printf '%q ' "$image" bash -s -- "$commit" "$(wc -l <"$LOCK")")"
) || die "the lock wasn't regenerated (above); $LOCK is unchanged"
grep -q '==' <<<"$packages" || die "the GPU Node printed no packages; $LOCK is unchanged"

old=$(grep -v '^#' "$LOCK")
# The header is the lock's leading comment lines.
{ awk '!/^#/ { exit } 1' "$LOCK" && printf '%s\n' "$packages"; } >"$LOCK.new"
mv "$LOCK.new" "$LOCK"
if [[ $old == "$packages" ]]; then
  log "The lock is unchanged"
else
  log "The lock changed:"
  diff <(echo "$old") <(echo "$packages") | grep '^[<>]' || true
fi

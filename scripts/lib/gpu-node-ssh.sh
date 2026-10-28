# Reaching the GPU Node from the Host, over ssh as k3dlab (ADR 0005). Sourced by lib.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

# The key the Host logs in to the GPU Node with, as k3dlab (just gpu wizard).
GPU_NODE_SSH_KEY=$HOME/.ssh/k3d-lab_ed25519

# ssh to the GPU Node as k3dlab. Never prompts and gives up quickly, so a GPU Node
# that's off never holds anything up.
gpu_ssh() {
  need_env GPU_NODE_SSH
  ssh -i "$GPU_NODE_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new "$GPU_NODE_SSH" "$@"
}
gpu_node_reachable() { gpu_ssh sudo -n true 2>/dev/null; }

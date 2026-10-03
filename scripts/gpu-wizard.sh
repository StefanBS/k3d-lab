#!/usr/bin/env bash
# Walks you through the GPU Node step only you can do: creating the k3dlab user that
# the Host logs in as (ADRs 0002 and 0005). It runs once, with sudo as you on the GPU
# Node, before that user exists. Then tests the login.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

need_env GPU_NODE_IP GPU_NODE_SSH

if [[ ! -f $GPU_NODE_SSH_KEY ]]; then
  log "Generating the Host's key for the GPU Node, $GPU_NODE_SSH_KEY"
  ssh-keygen -q -t ed25519 -N '' -C 'k3d-lab gpu-join' -f "$GPU_NODE_SSH_KEY"
fi
pubkey=$(<"$GPU_NODE_SSH_KEY.pub")

cat <<EOF
Create the k3dlab user on the GPU Node. From here, as your own user there, who can sudo:

  scp $LAB_ROOT/scripts/gpu-node.sh <you>@$GPU_NODE_IP:
  ssh -t <you>@$GPU_NODE_IP sudo bash gpu-node.sh setup '$pubkey'

It's safe to run again: it replaces k3dlab's key with this one.

EOF
read -rp "Has setup finished? [y/N] " reply || true
[[ $reply == [Yy]* ]] || die "nothing tested; run 'just gpu wizard' again once setup has run"

gpu_node_reachable || die "can't log in as $GPU_NODE_SSH with passwordless sudo; check the setup's output"
log "The Host logs in to the GPU Node as $GPU_NODE_SSH, with sudo; 'just gpu join' can run"

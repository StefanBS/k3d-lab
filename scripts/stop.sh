#!/usr/bin/env bash
# Stops the Lab, keeping all its state, until `just start`: the k3d Nodes first, then the
# Secret Store, which ESO reads from while they run. Neither starts again at boot.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/host.sh
source "$(dirname "$0")/lib/host.sh"
# shellcheck source=lib/secret-store.sh
source "$(dirname "$0")/lib/secret-store.sh"

if lab_exists; then
  # A Joined GPU Node keeps its pods running while the Lab is stopped, ComfyUI holding
  # its VRAM among them, since its agent runs on another machine. Only a leave frees it,
  # and a stop shouldn't end a job, so it's left to you.
  if node=$(gpu_node_object 2>/dev/null) && [[ $node == *" Ready" ]]; then
    warn "the GPU Node is Joined, so its pods keep the GPU while the Lab is stopped; 'just gpu leave' frees it"
  fi
  log "Stopping the k3d Nodes"
  quietly k3d cluster stop "$LAB_NAME"
fi

if secret_store_running; then
  log "Stopping the Secret Store"
  systemctl --user stop "$SECRET_STORE_UNIT"
fi

log "The Lab is stopped; 'just start' starts it again"

#!/usr/bin/env bash
# Starts the Lab again after `just stop` or a reboot of the Host, keeping all its state:
# the Secret Store first, since ESO reads from it, then the k3d Nodes. Neither starts at
# boot by itself. With no Lab, it starts only the Secret Store, for `just up`.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/host.sh
source "$(dirname "$0")/lib/host.sh"
# shellcheck source=lib/secret-store.sh
source "$(dirname "$0")/lib/secret-store.sh"

[[ -f $SECRET_STORE_INIT ]] || die "the Secret Store isn't set up yet; run 'just host setup'"
if secret_store_unsealed; then
  log "The Secret Store is already running"
else
  log "Starting the Secret Store"
  secret_store_restart
fi

if ! lab_exists; then
  log "There's no Lab to start; 'just up' builds one"
  exit
fi
log "Starting the k3d Nodes"
quietly k3d cluster start "$LAB_NAME"
settle_start
log "The Lab is running"

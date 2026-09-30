#!/usr/bin/env bash
# Destroys the Lab: the cluster and its Docker network. Nothing on the Host outside them is touched.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if lab_exists; then
  log "Deleting the k3d cluster"
  k3d cluster delete "$LAB_NAME"
fi

if docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; then
  log "Removing the Lab network $LAB_NETWORK"
  docker network rm "$LAB_NETWORK" >/dev/null
fi

# One line per thing that should be gone but isn't.
leftovers=$(
  lab_exists && echo "cluster: $LAB_NAME"
  docker network inspect "$LAB_NETWORK" >/dev/null 2>&1 && echo "network: $LAB_NETWORK"
  ip -br link show "$LAB_BRIDGE" >/dev/null 2>&1 && echo "bridge: $LAB_BRIDGE"
  docker volume ls -q --filter "name=k3d-$LAB_NAME" | sed 's/^/volume: /'
  kubectl config get-contexts -o name | grep -x "$LAB_CONTEXT" | sed 's/^/kube context: /'
  true # finding nothing is success, whatever the last check returned
)
[[ -z $leftovers ]] || die "the Lab left things behind:
$leftovers"

log "The Lab is down"

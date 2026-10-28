# The Lab's names and addresses, and reaching it. Sourced by lib.sh, and on its own by
# scripts/tests/, so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

LAB_NAME=lab
LAB_CONTEXT=k3d-$LAB_NAME
LAB_NETWORK=k3d-$LAB_NAME
LAB_BRIDGE=br-k3d-lab
LAB_SUBNET=172.28.0.0/16
LAB_SUBNET_NETMASK=255.255.0.0 # LAB_SUBNET's /16, for the Lab CA's name constraints
LAB_GATEWAY=172.28.0.1
# The Server is the first container on the Lab network, so it always gets this address.
# Cilium's values and CoreDNS's entry for single sign-on pin it (lint checks they match),
# and up.sh checks it got it.
LAB_SERVER_IP=172.28.0.2

# What the scripts record about the Lab, outside the repo.
LAB_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/k3d-lab

# need_env <name>...: fails unless .env sets each variable.
need_env() {
  local name
  for name; do
    [[ -n ${!name:-} ]] || die "$name isn't set: copy .env.example to .env and fill it in"
  done
}

# kubectl, always against the Lab, whatever the current context is.
kc() { kubectl --context "$LAB_CONTEXT" "$@"; }

lab_exists() { k3d cluster get "$LAB_NAME" >/dev/null 2>&1; }
need_lab() { lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"; }
lab_network_exists() { docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; }

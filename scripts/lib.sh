# Shared by the Lab's scripts: sourced, never run directly.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

set -euo pipefail

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The tools come from mise.toml, at the versions CI uses, whatever the caller's PATH
# holds. Without mise, the scripts use PATH as it is, and doctor says what's missing.
if command -v mise >/dev/null; then
  eval "$(cd "$LAB_ROOT" && mise env --shell bash)"
fi

# ADR 0001: the k3d Nodes run on Docker CE. Never trust the caller's DOCKER_HOST,
# which may point at another engine, such as Podman or rootless Docker.
export DOCKER_HOST=unix:///var/run/docker.sock

LAB_NAME=lab
LAB_CONTEXT=k3d-$LAB_NAME
LAB_NETWORK=k3d-$LAB_NAME
LAB_BRIDGE=br-k3d-lab
LAB_SUBNET=172.28.0.0/16
LAB_SUBNET_NETMASK=255.255.0.0 # LAB_SUBNET's /16, for the Lab CA's name constraints
LAB_GATEWAY=172.28.0.1
# ArgoCD reads the Lab from here, without credentials.
LAB_REPO=https://github.com/StefanBS/k3d-lab.git
# Machine-specific values, never committed (.env.example lists them).
LAB_ENV_FILE=$LAB_ROOT/.env

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Runs a command, showing its output only if it fails. For tools like k3d and helm,
# whose progress logs and release notes would bury the Lab's own messages.
quietly() {
  local out status=0
  out=$("$@" 2>&1) || status=$?
  ((status == 0)) || printf '%s\n' "$out" >&2
  return "$status"
}

# need_env <name>...: fails unless .env (loaded by the Justfile) sets each variable.
need_env() {
  local name
  for name; do
    [[ -n ${!name:-} ]] || die "$name isn't set: copy .env.example to .env and fill it in"
  done
}

# For the scripts that report one line per check: doctor, lint and the host-setup
# scripts print with these. doctor and lint count their failures in fails, and exit
# non-zero if there are any.
fails=0
ok() { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

# retry <tries> <command>...: runs the command once a second until it succeeds, giving
# up after that many tries.
retry() {
  local tries=$1
  shift
  until "$@"; do
    ((--tries > 0)) || return 1
    sleep 1
  done
}

# kubectl, always against the Lab, whatever the current context is.
kc() { kubectl --context "$LAB_CONTEXT" "$@"; }

lab_exists() { k3d cluster get "$LAB_NAME" >/dev/null 2>&1; }

# The Server's container, and its address on the Lab network.
LAB_SERVER=k3d-$LAB_NAME-server-0
lab_server_ip() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress}}" "$LAB_SERVER"
}

# The GPU Node (ADRs 0002 and 0005), always found by its label, never by hostname.
GPU_NODE_LABEL_KEY=k3d-lab/gpu
GPU_NODE_LABEL=$GPU_NODE_LABEL_KEY=amd
GPU_NODE_TAINT=amd.com/gpu:NoSchedule
# The key the Host logs in to the GPU Node with, as k3dlab (just gpu-wizard).
GPU_NODE_SSH_KEY=$HOME/.ssh/k3d-lab_ed25519

# The GPU Node's Node object in the Lab, if it's Joined: its name and Ready status.
gpu_node_in_lab() {
  kc get nodes -l "$GPU_NODE_LABEL_KEY" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
}

# ssh to the GPU Node as k3dlab. Never prompts and gives up quickly, so a GPU Node
# that's off never holds anything up.
gpu_ssh() {
  need_env GPU_NODE_SSH
  ssh -i "$GPU_NODE_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new "$GPU_NODE_SSH" "$@"
}
gpu_node_reachable() { gpu_ssh sudo -n true 2>/dev/null; }
lab_network_exists() { docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; }

# The Host's ports that k3d publishes the Lab's Gateway on (k3d/cluster.yaml).
LAB_HOST_PORTS=(80 443)

# Prints the Host's listening sockets on any of LAB_HOST_PORTS, one per line.
lab_host_ports_taken() {
  local filter port
  for port in "${LAB_HOST_PORTS[@]}"; do filter+="${filter:+ or }sport = :$port"; done
  ss -ltnH "( $filter )" | awk '{ print $4 }'
}

# The Host's route to the LAN, and its address there (HOST_LAN_IP, ADR 0002).
host_route() { ip -4 route get 1.1.1.1; }
host_lan_ip() { host_route | sed -n 's/.* src \([0-9.]*\).*/\1/p'; }

# Every component folder, as <group>/<name>: one ArgoCD Application each.
component_dirs() {
  local file
  for file in "$LAB_ROOT"/{platform,workloads}/*/component.yaml; do
    [[ -f $file ]] || continue # an empty group leaves its glob unexpanded
    file=${file#"$LAB_ROOT"/}
    echo "${file%/component.yaml}"
  done
}

# Whether a component folder installs a chart; otherwise its kustomization.yaml is the
# component (the Platform and Workloads ApplicationSets decide the same way).
component_has_chart() { [[ $(yq 'has("chart")' "$LAB_ROOT/$1/component.yaml") == true ]]; }

# The arguments that make `helm template` or `helm upgrade --install` render a component
# the way ArgoCD does: its pinned chart, namespace and values. One per line, for mapfile.
component_helm_args() {
  local dir=$LAB_ROOT/$1
  local component=$dir/component.yaml
  printf '%s\n' \
    "$(yq '.chart' "$component")" \
    --repo "$(yq '.repoURL' "$component")" \
    --version "$(yq '.version' "$component")" \
    --namespace "$(yq '.namespace' "$component")" \
    --values "$dir/values.yaml"
}

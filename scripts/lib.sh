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

# kubectl, always against the Lab, whatever the current context is.
kc() { kubectl --context "$LAB_CONTEXT" "$@"; }

lab_exists() { k3d cluster get "$LAB_NAME" >/dev/null 2>&1; }
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

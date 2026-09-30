# Shared by the Lab's scripts: sourced, never run directly.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

set -euo pipefail

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The tools come from mise.toml, at the versions CI uses, whatever the caller's PATH
# holds. Without mise, the scripts use PATH as it is, and doctor says what's missing.
# Not as root: host-setup-root.sh runs under sudo, where mise would write root-owned
# files into the owner's home.
if ((EUID != 0)) && command -v mise >/dev/null; then
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

# ADR 0001: Docker CE's data directory, on /home because the root volume is small.
DOCKER_DATA_ROOT=/home/docker-data

# ADR 0003: the Lab CA, generated once by host-setup, outside the repo, and trusted by
# the Host through the anchor below (Fedora's ca-trust). host-setup-root.sh points
# HOME at the owner's before sourcing this.
LAB_CA_DIR=$HOME/.local/share/k3d-lab/ca
LAB_CA_CERT=$LAB_CA_DIR/ca.crt
LAB_CA_KEY=$LAB_CA_DIR/ca.key
LAB_CA_ANCHOR=/etc/pki/ca-trust/source/anchors/k3d-lab-ca.crt

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# For the scripts that report one line per check: doctor, lint and the host-setup
# scripts print with these, verify with its own check(). doctor and lint count their
# failures in fails, and exit non-zero if there are any.
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

# Every component folder, as <group>/<name>: one ArgoCD Application each.
component_dirs() {
  local file
  for file in "$LAB_ROOT"/{platform,workloads}/*/component.yaml; do
    [[ -f $file ]] || continue # an empty group leaves its glob unexpanded
    file=${file#"$LAB_ROOT"/}
    echo "${file%/component.yaml}"
  done
}

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

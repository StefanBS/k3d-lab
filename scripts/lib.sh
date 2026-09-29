# Shared by the Lab's scripts: sourced, never run directly.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

set -euo pipefail

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ADR 0001: the k3d Nodes run on Docker CE. Never trust the caller's DOCKER_HOST,
# which may still point at Podman in shells started before the switch.
export DOCKER_HOST=unix:///var/run/docker.sock

LAB_NAME=lab
LAB_CONTEXT=k3d-$LAB_NAME
LAB_NETWORK=k3d-$LAB_NAME
LAB_BRIDGE=br-k3d-lab
LAB_SUBNET=172.28.0.0/16
LAB_GATEWAY=172.28.0.1
# ArgoCD reads the Lab from here, without credentials.
LAB_REPO=https://github.com/StefanBS/k3d-lab.git

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# kubectl, always against the Lab, whatever the current context is.
kc() { kubectl --context "$LAB_CONTEXT" "$@"; }

lab_exists() { k3d cluster get "$LAB_NAME" >/dev/null 2>&1; }

# Reads a top-level scalar from a flat YAML file (yq isn't a prerequisite),
# dropping a trailing comment and surrounding quotes.
yaml_get() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n1 |
    sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# Every component folder, as <group>/<name>: one ArgoCD Application each.
component_dirs() {
  (cd "$LAB_ROOT" && for f in platform/*/component.yaml workloads/*/component.yaml; do
    [[ -f $f ]] && dirname "$f"
  done)
}

# The arguments that make `helm template` or `helm upgrade --install` render a component
# the way ArgoCD does: its pinned chart, namespace and values. One per line, for mapfile.
component_helm_args() {
  local dir=$LAB_ROOT/$1
  printf '%s\n' \
    "$(yaml_get "$dir/component.yaml" chart)" \
    --repo "$(yaml_get "$dir/component.yaml" repoURL)" \
    --version "$(yaml_get "$dir/component.yaml" version)" \
    --namespace "$(yaml_get "$dir/component.yaml" namespace)" \
    --values "$dir/values.yaml"
}

#!/usr/bin/env bash
# Builds the Lab from scratch, then runs verify.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

lab_exists && die "a Lab already exists; run 'just down' first"

# Makes / rshared inside the k3d Nodes, which Cilium's bpffs mount needs.
export K3D_FIX_MOUNTS=1

log "Creating the Lab network $LAB_NETWORK ($LAB_SUBNET)"
if docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; then
  # The Server must be the first container on the network to get its fixed address.
  [[ $(docker network inspect -f '{{len .Containers}}' "$LAB_NETWORK") -eq 0 ]] ||
    die "network $LAB_NETWORK still has containers attached; run 'just down' first"
else
  # nat-unprotected: Docker 28+ otherwise drops routed traffic from the GPU Node (ADR 0002).
  docker network create --driver bridge \
    --subnet "$LAB_SUBNET" --gateway "$LAB_GATEWAY" \
    -o com.docker.network.bridge.name="$LAB_BRIDGE" \
    -o com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected \
    "$LAB_NETWORK" >/dev/null
fi

log "Creating the k3d cluster"
k3d cluster create --config "$LAB_ROOT/k3d/cluster.yaml"

server_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress}}" "k3d-$LAB_NAME-server-0")
expected_ip=$(yaml_get "$LAB_ROOT/platform/cilium/values.yaml" k8sServiceHost)
[[ $server_ip == "$expected_ip" ]] ||
  die "the Server got $server_ip, but Cilium's values expect $expected_ip; run 'just down' and try again"

# Installs a Platform component from its folder with Helm: the same chart, version
# and values that ArgoCD uses for it.
install_component() {
  local name=$1 dir=$LAB_ROOT/platform/$1
  log "Installing $name"
  helm upgrade --install "$name" "$(yaml_get "$dir/component.yaml" chart)" \
    --kube-context "$LAB_CONTEXT" \
    --repo "$(yaml_get "$dir/component.yaml" repoURL)" \
    --version "$(yaml_get "$dir/component.yaml" version)" \
    --namespace "$(yaml_get "$dir/component.yaml" namespace)" \
    --values "$dir/values.yaml" \
    --wait --timeout 10m
}

install_component cilium

log "Waiting for every node to be Ready"
kc wait --for=condition=Ready nodes --all --timeout=5m >/dev/null

exec "$LAB_ROOT/scripts/verify.sh"

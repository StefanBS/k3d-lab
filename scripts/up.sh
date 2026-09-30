#!/usr/bin/env bash
# Builds the Lab from scratch, then runs verify.
# Usage: up.sh [REVISION=<branch or tag>]. ArgoCD reads the Lab from that revision
# of LAB_REPO, main by default.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

revision=main
for arg; do
  case $arg in
    REVISION=?*) revision=${arg#REVISION=} ;;
    *) die "unknown argument '$arg'; usage: just up [REVISION=<branch>]" ;;
  esac
done

# Installs a Platform component that ArgoCD can't install itself: the same chart,
# version and values that ArgoCD then manages it with.
install_component() {
  local name=$1 args
  mapfile -t args < <(component_helm_args "platform/$name")
  log "Installing $name"
  helm upgrade --install "$name" "${args[@]}" --create-namespace \
    --kube-context "$LAB_CONTEXT" --wait --timeout 10m
}

lab_exists && die "a Lab already exists; run 'just down' first"
git ls-remote --exit-code "$LAB_REPO" "refs/heads/$revision" "refs/tags/$revision" >/dev/null ||
  die "'$revision' isn't a branch or tag of $LAB_REPO; push it first"

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
# k3d runs every /bin/k3d-entrypoint-*.sh at each k3d Node start. Mounted here rather
# than in cluster.yaml, which would need the repo's absolute path.
k3d cluster create --config "$LAB_ROOT/k3d/cluster.yaml" \
  --volume "$LAB_ROOT/k3d/entrypoint-route-localnet.sh:/bin/k3d-entrypoint-route-localnet.sh:ro@all"

server_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress}}" "k3d-$LAB_NAME-server-0")
expected_ip=$(yaml_get "$LAB_ROOT/platform/cilium/values.yaml" k8sServiceHost)
[[ $server_ip == "$expected_ip" ]] ||
  die "the Server got $server_ip, but Cilium's values expect $expected_ip; run 'just down' and try again"

install_component cilium

log "Waiting for every node to be Ready"
kc wait --for=condition=Ready nodes --all --timeout=5m >/dev/null

install_component argocd

# From here on, Git is the only source of truth: ArgoCD takes over Cilium and itself,
# and installs everything else.
log "Handing the Lab over to ArgoCD, tracking $revision"
kc apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $LAB_REPO
    targetRevision: "$revision"
    path: gitops
    helm:
      valuesObject:
        repoURL: $LAB_REPO
        revision: "$revision"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# The root Application is Healthy once both ApplicationSets have generated their
# Applications, so from then on every Application exists to be waited for.
log "Waiting for ArgoCD to sync the Lab"
kc -n argocd wait application/root --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m >/dev/null
kc -n argocd wait applications --all --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m >/dev/null
kc -n argocd wait applications --all --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m >/dev/null

exec "$LAB_ROOT/scripts/verify.sh"

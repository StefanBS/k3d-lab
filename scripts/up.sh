#!/usr/bin/env bash
# Builds the Lab from scratch, then runs verify.
# Usage: up.sh [REVISION=<branch or tag>]. ArgoCD reads the Lab from that revision
# of LAB_REPO. By default, that's the branch checked out here, since verify runs the
# checks from this checkout: a Lab built from another branch would fail checks it was
# never meant to pass.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

revision=$(git -C "$LAB_ROOT" branch --show-current)
for arg; do
  case $arg in
    REVISION=?*) revision=${arg#REVISION=} ;;
    *) die "unknown argument '$arg'; usage: just up [REVISION=<branch>]" ;;
  esac
done
[[ -n $revision ]] || die "no branch is checked out; check one out, or pass REVISION=<branch or tag>"

# Installs a Platform component that ArgoCD can't install itself: the same chart,
# version and values that ArgoCD then manages it with.
install_component() {
  local name=$1 args
  mapfile -t args < <(component_helm_args "platform/$name")
  log "Installing $name"
  quietly helm upgrade --install "$name" "${args[@]}" --create-namespace \
    --kube-context "$LAB_CONTEXT" --wait --timeout 10m
}

lab_exists && die "a Lab already exists; run 'just down' first"
lab_ca_exists || die "the Lab CA isn't in $LAB_CA_DIR; run 'just host-setup'"
taken=$(lab_host_ports_taken)
[[ -z $taken ]] || die "the Lab's Gateway needs these Host ports, but something already listens there:
$taken"
remote_commit=$(git ls-remote "$LAB_REPO" "refs/heads/$revision" "refs/tags/$revision" | awk 'NR == 1 { print $1 }')
[[ -n $remote_commit ]] || die "'$revision' isn't a branch or tag of $LAB_REPO; push it first"
# ArgoCD reads what's pushed, while verify runs the checks as they are here.
if [[ $revision == "$(git -C "$LAB_ROOT" branch --show-current)" &&
  $remote_commit != "$(git -C "$LAB_ROOT" rev-parse HEAD)" ]]; then
  warn "$revision here isn't the commit $LAB_REPO has; the Lab is built from what's pushed"
fi

# Makes / rshared inside the k3d Nodes, which Cilium's bpffs mount needs.
export K3D_FIX_MOUNTS=1

log "Creating the Lab network $LAB_NETWORK ($LAB_SUBNET)"
if lab_network_exists; then
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
quietly k3d cluster create --config "$LAB_ROOT/k3d/cluster.yaml" \
  --volume "$LAB_ROOT/k3d/entrypoint-route-localnet.sh:/bin/k3d-entrypoint-route-localnet.sh:ro@all"

server_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress}}" "k3d-$LAB_NAME-server-0")
expected_ip=$(yq '.k8sServiceHost' "$LAB_ROOT/platform/cilium/values.yaml")
[[ $server_ip == "$expected_ip" ]] ||
  die "the Server got $server_ip, but Cilium's values expect $expected_ip; run 'just down' and try again"

# Cilium only runs its Gateway controller if the Gateway API CRDs exist when it starts.
log "Installing the Gateway API CRDs"
kc apply --server-side -k "$LAB_ROOT/platform/gateway-api" >/dev/null

install_component cilium

log "Waiting for every node to be Ready"
kc wait --for=condition=Ready nodes --all --timeout=5m >/dev/null

install_component argocd

# The Lab CA's key never goes in Git: cert-manager's lab-ca ClusterIssuer
# (platform/cert-manager/values.yaml) signs with it from this Secret (ADR 0003).
log "Loading the Lab CA into cert-manager"
cert_manager_ns=$(yq '.namespace' "$LAB_ROOT/platform/cert-manager/component.yaml")
kc create namespace "$cert_manager_ns" >/dev/null
kc -n "$cert_manager_ns" create secret tls lab-ca --cert "$LAB_CA_CERT" --key "$LAB_CA_KEY" >/dev/null

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

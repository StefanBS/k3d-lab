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
# shellcheck source=secret-store.sh
source "$(dirname "$0")/secret-store.sh"

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
lab_ca_exists || die "the Lab CA isn't in $LAB_CA_DIR; run 'just host setup'"
secret_store_unsealed || die "the Secret Store isn't running and unsealed; run 'just host setup'"
taken=$(lab_host_ports_taken)
[[ -z $taken ]] || die "the Lab's Gateway needs these Host ports, but something already listens there:
$taken"
pushed_commit "$revision" >/dev/null

# Makes / rshared inside the k3d Nodes, which Cilium's bpffs mount needs.
export K3D_FIX_MOUNTS=1

log "Creating the Lab network $LAB_NETWORK ($LAB_SUBNET)"
if lab_network_exists; then
  # The Server must be the first container on the network to get the address it's then
  # pinned to.
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

server_ip=$(lab_server_ip)
[[ $server_ip == "$LAB_SERVER_IP" ]] ||
  die "the Server got $server_ip, but Cilium's values expect LAB_SERVER_IP ($LAB_SERVER_IP); run 'just down' and try again"

# Docker only keeps a container's address across its own restart, such as a Host
# reboot, if the address is static; otherwise the k3d Nodes come back in whichever
# order they start. k3d only gives addresses on a network it creates itself, which
# can't be this one (ADR 0002). So each k3d Node is reconnected, stopped, with the
# address it already has: k3s has already put that address in its certificates.
log "Pinning the k3d Nodes' addresses"
# Each k3d Node's name and CIDR address, one per line.
nodes=$(docker network inspect "$LAB_NETWORK" \
  -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}')
quietly k3d cluster stop "$LAB_NAME"
while read -r node cidr; do
  [[ -n $node ]] || continue
  docker network disconnect "$LAB_NETWORK" "$node"
  docker network connect --ip "${cidr%/*}" "$LAB_NETWORK" "$node"
done <<<"$nodes"
quietly k3d cluster start "$LAB_NAME"

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
cert_manager_ns=$(component_namespace platform/cert-manager)
kc create namespace "$cert_manager_ns" >/dev/null
kc -n "$cert_manager_ns" create secret tls lab-ca --cert "$LAB_CA_CERT" --key "$LAB_CA_KEY" >/dev/null

# ESO reads Workloads' secrets from the Secret Store on the Host (ADR 0003), and each
# new Lab has to be introduced to it.
secret_store_trust_lab

# From here on, Git is the only source of truth: ArgoCD takes over Cilium and itself,
# and installs everything else.
log "Handing the Lab over to ArgoCD, tracking $revision"
# The root Application runs in the platform project, which the root Application itself
# syncs. So the projects are applied first, rendered from the same chart, as ArgoCD then
# renders them.
helm template gitops "$LAB_ROOT/gitops" --show-only templates/appprojects.yaml |
  kc apply -f - >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: platform
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
    syncOptions:
      - RespectIgnoreDifferences=true
  # The sync windows that 'just pause' adds to a project stay, until 'just resume'. Git
  # sets none, so the whole list is left to the Lab: a window added in Git would not apply.
  ignoreDifferences:
    - group: argoproj.io
      kind: AppProject
      jsonPointers:
        - /spec/syncWindows
EOF

# The root Application can be Healthy before it has even created the ApplicationSets,
# so they are waited for by name, rendered from the same chart. Once each says
# ResourcesUpToDate, every Application exists to be waited for: `wait --all` waits only
# for those it finds when it starts.
log "Waiting for ArgoCD to sync the Lab"
mapfile -t appsets < <(helm template gitops "$LAB_ROOT/gitops" --show-only templates/applicationsets.yaml |
  yq -N 'select(.kind == "ApplicationSet") | "applicationset/" + .metadata.name')
# One at a time: given several, --for=create fails at once on any that don't exist yet.
for appset in "${appsets[@]}"; do
  kc -n argocd wait "$appset" --for=create --timeout=5m >/dev/null
done
kc -n argocd wait "${appsets[@]}" --for=condition=ResourcesUpToDate --timeout=5m >/dev/null
kc -n argocd wait application/root --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m >/dev/null
kc -n argocd wait applications --all --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m >/dev/null
kc -n argocd wait applications --all --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m >/dev/null

exec "$LAB_ROOT/scripts/verify.sh"

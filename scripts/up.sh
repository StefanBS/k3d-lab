#!/usr/bin/env bash
# Builds the Lab from scratch, and stops once every Application is Settled.
# Usage: up.sh [REVISION=<branch or tag>] [--demos] [--debug]. ArgoCD reads the Lab from that
# revision of LAB_REPO. By default, that's the branch checked out here, since verify runs
# the checks from this checkout: a Lab built from another branch would fail checks it was
# never meant to pass.
# --demos also builds the Demos, which a Lab that's only used doesn't need.
# --debug makes it a debugging run, which also records the pressure and ends with verify
# (run-diagnostics.sh). That's the test of a change, so it builds the Demos too: it must
# cover all of Git.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/host.sh
source "$(dirname "$0")/lib/host.sh"
# shellcheck source=lib/secret-store.sh
source "$(dirname "$0")/lib/secret-store.sh"
# shellcheck source=lib/run-diagnostics.sh
source "$(dirname "$0")/lib/run-diagnostics.sh"

revision=$(git -C "$LAB_ROOT" branch --show-current)
demos=false
debug=''
for arg; do
  case $arg in
    REVISION=?*) revision=${arg#REVISION=} ;;
    --demos) demos=true ;;
    --debug)
      debug=1
      demos=true
      ;;
    *) die "unknown argument '$arg'; usage: just up [REVISION=<branch>] [--demos] [--debug]" ;;
  esac
done
[[ -n $revision ]] || die "no branch is checked out; check one out, or pass REVISION=<branch or tag>"

# k3s may stall on its datastore during the build or the checks, and the Pressure then
# says why (run-diagnostics.sh).
[[ -z $debug ]] || record_pressure

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
# Before anything is built: without them Dex never starts, and a sync that never ends
# says nothing of why.
sso_missing=$(sso_secrets_missing) || die "can't read single sign-on's secrets from the Secret Store"
[[ -z $sso_missing ]] || die "the Secret Store lacks what single sign-on needs; run 'just host setup'. Missing, under lab/:
$sso_missing"
taken=$(lab_host_ports_taken)
[[ -z $taken ]] || die "the Lab's Gateway needs these Host ports, but something already listens there:
$taken"
commit=$(pushed_commit "$revision")
trap 'report_run up "$debug"' EXIT

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
# Stopping and starting the k3d Nodes restarted k3s on the Server on purpose. Any restart
# after this is reported (#135), by verify in a debugging run: k3s dying on its datastore
# while ArgoCD syncs would otherwise go unseen.
start_run_clock

# Cilium only runs its Gateway controller if the Gateway API CRDs exist when it starts.
log "Installing the Gateway API CRDs"
kc apply --server-side -k "$LAB_ROOT/platform/gateway-api" >/dev/null

install_component cilium

log "Waiting for every node to be Ready"
wait_nodes_ready 300

# What signs in through Dex calls it over TLS from the Lab CA (ADR 0013), and trusts it
# from this ConfigMap. argocd-server mounts it, so ArgoCD's comes before ArgoCD; Dex's
# other clients start later, once ArgoCD syncs them.
log "Giving single sign-on's clients the Lab CA"
for component in argocd grafana oauth2-proxy; do
  lab_ca_configmap "$(component_namespace "platform/$component")"
done

install_component argocd

# The Lab CA's key never goes in Git: cert-manager's lab-ca ClusterIssuer
# (platform/cert-manager/values.yaml) signs with it from this Secret (ADR 0003).
log "Loading the Lab CA into cert-manager"
cert_manager_ns=$(component_namespace platform/cert-manager)
kc create namespace "$cert_manager_ns" >/dev/null
kc -n "$cert_manager_ns" create secret tls lab-ca --cert "$LAB_CA_CERT" --key "$LAB_CA_KEY" >/dev/null

# ESO reads secrets from the Secret Store on the Host (ADR 0003), and each new Lab has
# to be introduced to it.
secret_store_trust_lab

# From here on, Git is the only source of truth: ArgoCD takes over Cilium and itself,
# and installs everything else.
log "Handing the Lab over to ArgoCD, tracking $revision"
# The root Application runs in the platform project, which the root Application itself
# syncs. So the projects are applied first, rendered from the same chart, as ArgoCD then
# renders them.
helm template gitops "$LAB_ROOT/gitops" --show-only templates/appprojects.yaml |
  kc apply -f - >/dev/null
root_application_manifest "$revision" "$demos" | kc apply -f - >/dev/null

# The root Application can be Healthy before it has even created the ApplicationSets,
# so they are waited for by name, rendered from the same chart. Once each says
# ResourcesUpToDate, every Application exists to be waited for: the wait for them to be
# Settled counts only those that ArgoCD lists. The root Application creates each
# ApplicationSet once the Platform's waves before it are Healthy, so the last is created
# near the end of the Platform's install: the wait is that long.
log "Waiting for ArgoCD to sync the Lab"
mapfile -t appsets < <(helm template gitops "$LAB_ROOT/gitops" --show-only templates/applicationsets.yaml |
  yq -N 'select(.kind == "ApplicationSet") | .metadata.name')
# Without names, the wait would count whichever ApplicationSets are listed.
((${#appsets[@]})) || die "the gitops chart renders no ApplicationSets"
wait_applicationsets 900 "${appsets[@]}"
wait_settled 900 --at "$commit"

[[ -z $debug ]] || exec "$LAB_ROOT/scripts/verify.sh"

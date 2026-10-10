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
# The Server is the first container on the Lab network, so it always gets this address.
# Cilium's values pin it (lint checks they match), and up.sh checks it got it.
LAB_SERVER_IP=172.28.0.2
# ArgoCD reads the Lab from here, without credentials.
LAB_REPO=https://github.com/StefanBS/k3d-lab.git
# Machine-specific values, never committed (.env.example lists them). Loaded here, so
# the scripts see them also when run without just.
LAB_ENV_FILE=$LAB_ROOT/.env
if [[ -f $LAB_ENV_FILE ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$LAB_ENV_FILE"
  set +a
fi

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

# need_env <name>...: fails unless .env sets each variable.
need_env() {
  local name
  for name; do
    [[ -n ${!name:-} ]] || die "$name isn't set: copy .env.example to .env and fill it in"
  done
}

# For the scripts that report one line per check: doctor, lint and the host setup
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

# What the scripts record about the Lab, outside the repo.
LAB_STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/k3d-lab

# verify, and a debugging run of up or track, record the pressure with below (below.sh),
# with its config, store and log in this directory.
LAB_BELOW_DIR=$LAB_STATE_DIR/below
LAB_BELOW_CONFIG=$LAB_BELOW_DIR/below.conf

# record_pressure: records the pressure on the Host and on each cgroup in it with below
# until this script exits, failed or not. verify run by up or track keeps their recorder.
record_pressure() {
  [[ -z ${LAB_BELOW_RECORDING:-} ]] || return 0
  if ! command -v below >/dev/null; then
    log "warning: below isn't installed, so this run records no pressure; see 'just doctor'"
    return 0
  fi
  # Two recorders would write to the same store, as when verify runs beside up.
  if pgrep -u "$(id -u)" -f "^below --config $LAB_BELOW_CONFIG record" >/dev/null; then
    log "warning: another run is recording the pressure, so the record of this one ends with it"
    return 0
  fi
  export LAB_BELOW_RECORDING=1
  # The recorder stops once this script's PID is gone, which exec keeps, so a failed run
  # stops it too. It writes nowhere else: a pipe the script writes to, such as tee's,
  # would otherwise stay open until it stops.
  "$LAB_ROOT/scripts/below-recorder.sh" "$$" >/dev/null 2>&1 &
}

# kubectl, always against the Lab, whatever the current context is.
kc() { kubectl --context "$LAB_CONTEXT" "$@"; }

lab_exists() { k3d cluster get "$LAB_NAME" >/dev/null 2>&1; }

# pushed_commit <branch or tag>: prints the commit LAB_REPO has for it, the one ArgoCD
# reads, and fails if LAB_REPO doesn't have it. verify runs the checks as they are here,
# so it warns when the branch checked out here isn't that commit.
pushed_commit() {
  local revision=$1 commit
  # An annotated tag is listed twice: as itself, then peeled (^{}) to its commit, which
  # is what ArgoCD records. A branch comes first, as ArgoCD prefers it too.
  commit=$(git ls-remote "$LAB_REPO" "refs/heads/$revision" "refs/tags/$revision" "refs/tags/$revision^{}" |
    awk -v branch="refs/heads/$revision" -v tag="refs/tags/$revision" '
      $2 == branch { b = $1 }
      $2 == tag "^{}" { peeled = $1 }
      $2 == tag { plain = $1 }
      END { print (b != "" ? b : peeled != "" ? peeled : plain) }')
  [[ -n $commit ]] || die "'$revision' isn't a branch or tag of $LAB_REPO; push it first"
  if [[ $revision == "$(git -C "$LAB_ROOT" branch --show-current)" &&
    $commit != "$(git -C "$LAB_ROOT" rev-parse HEAD)" ]]; then
    log "warning: $revision here isn't the commit $LAB_REPO has; the Lab runs what's pushed"
  fi
  echo "$commit"
}

# The Server's container, and its address on the Lab network.
LAB_SERVER=k3d-$LAB_NAME-server-0
lab_server_ip() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress}}" "$LAB_SERVER"
}

# The GPU Node (ADRs 0002 and 0005), always found by its label, never by hostname.
GPU_NODE_LABEL_KEY=k3d-lab/gpu
GPU_NODE_LABEL=$GPU_NODE_LABEL_KEY=amd
GPU_NODE_TAINT=amd.com/gpu:NoSchedule
# The key the Host logs in to the GPU Node with, as k3dlab (just gpu wizard).
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
# Succeeds if HOST_LAN_IP, from .env, is still the Host's address; otherwise prints how
# it differs. The GPU Node routes the Lab's subnet through it (ADR 0002).
host_lan_ip_current() {
  local actual
  actual=$(host_lan_ip)
  [[ ${HOST_LAN_IP:-} == "$actual" ]] && return
  echo "HOST_LAN_IP in .env (${HOST_LAN_IP:-unset}) isn't the Host's address ($actual)"
  return 1
}

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
    --namespace "$(component_namespace "$1")" \
    --values "$dir/values.yaml"
}

# component_namespace <group>/<name>: the namespace that component folder installs into.
component_namespace() { yq '.namespace' "$LAB_ROOT/$1/component.yaml"; }

# Platform facts: what the scripts need from the Platform's values, each a file and the
# yq expression that reads it there. Callers ask by name, so only this table knows how
# the values files are laid out, and lint checks that every fact still resolves.
declare -A PLATFORM_FACTS=(
  [argocd.host]='platform/argocd/values.yaml|.global.domain'
  [grafana.url]='platform/grafana/values.yaml|.["grafana.ini"].server.root_url'
  # The Secret ESO generates Grafana's admin login into.
  [grafana.admin-secret]='platform/grafana/values.yaml|.admin.existingSecret'
  [rollouts.host]='platform/argo-rollouts/values.yaml|.dashboard.httproute.hostnames[0]'
  # The audience of the tokens ESO logs in to the Secret Store with.
  [eso.audience]='platform/external-secrets/values.yaml|.extraObjects[0] | from_yaml | .spec.provider.vault.auth.kubernetes.serviceAccountRef.audiences[0]'
  # Where ESO reaches the Secret Store: the Lab network's gateway.
  [eso.gateway-ip]='platform/external-secrets/values.yaml|.hostAliases[] | select(.hostnames[] == "host.k3d.internal") | .ip'
  # Where Cilium reaches the Kubernetes API, before it can resolve anything.
  [cilium.server-ip]='platform/cilium/values.yaml|.k8sServiceHost'
)
# The facts that Git can't read from here, so they repeat a constant above: each fact's
# constant, by name. lint checks they match.
declare -A PLATFORM_PINNED_FACTS=(
  [eso.gateway-ip]=LAB_GATEWAY
  [cilium.server-ip]=LAB_SERVER_IP
)

# platform_fact <name>: prints that fact. Fails if there's no such fact, or if it
# doesn't resolve.
platform_fact() {
  local fact=${PLATFORM_FACTS[$1]:-} value
  [[ -n $fact ]] || die "no Platform fact named '$1'"
  # -e: fails when the expression finds nothing, or null, which it still prints.
  value=$(yq -e "${fact#*|}" "$LAB_ROOT/${fact%%|*}" 2>/dev/null) ||
    die "Platform fact '$1' doesn't resolve: no ${fact#*|} in ${fact%%|*}"
  printf '%s\n' "$value"
}

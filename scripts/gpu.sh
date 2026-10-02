#!/usr/bin/env bash
# The Host's half of the GPU Node's lifecycle (ADRs 0002 and 0005): what needs the Lab,
# such as its version, its token, draining and deleting the Node object. The GPU
# Node's half, gpu-node.sh, runs there over SSH.
# Usage: gpu.sh join [eviction=<size>] | leave [purge] | status
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Runs gpu-node.sh as root on the GPU Node: run_on_gpu_node <stdin> <subcommand> [<VAR=value>...]
# The script goes over stdin, then the first argument, which only join reads: so the
# token is never in a command line on either machine. Every gpu-node.sh run gets the
# Lab's subnet and the GPU Node's address, and the Lab's CA hash while a Lab exists.
run_on_gpu_node() {
  local input=$1 subcommand=$2 vars ca_hash
  shift 2
  vars=(LAB_SUBNET="$LAB_SUBNET" GPU_NODE_IP="$GPU_NODE_IP" "$@")
  if ca_hash=$(lab_ca_hash 2>/dev/null) && [[ -n $ca_hash ]]; then vars+=(LAB_CA_HASH="$ca_hash"); fi
  { cat "$LAB_ROOT/scripts/gpu-node.sh" && printf '%s\n' "$input"; } |
    gpu_ssh "sudo env $(printf '%q ' "${vars[@]}")bash -s -- $subcommand"
}

lab_token() { docker exec "$LAB_SERVER" cat /var/lib/rancher/k3s/server/node-token; }
# The token's first part, K10<the hash of the Lab's CA>: it tells this Lab's install
# from a Stale install (gpu-node.sh).
lab_ca_hash() {
  local token
  lab_exists && token=$(lab_token) && echo "${token%%::*}"
}

gpu_node_registered() { [[ -n $(gpu_node_in_lab) ]]; }

# Every DaemonSet has a Ready, up-to-date pod on each node it should run on: once the GPU
# Node is Ready, that means the Platform's networking, logs and metrics run there too.
daemonsets_ready() {
  kc get daemonsets -A -o jsonpath='{range .items[*]}{.status.desiredNumberScheduled} {.status.numberReady} {.status.updatedNumberScheduled}{"\n"}{end}' |
    awk '$1 != $2 || $1 != $3 { bad = 1 } END { exit bad }'
}

# Fails, listing them, if the GPU Node has anything a Left GPU Node mustn't, or, with
# purge, anything the join added.
check_left() {
  local purge=$1 status bad
  status=$(run_on_gpu_node "" status)
  bad=$(grep -e '^agent: running' -e '^leftover: ' <<<"$status") || true
  [[ $purge == false ]] || bad+=$(grep -e '^installed: ' -e '^install: [^n]' <<<"$status") || true
  [[ -z $bad ]] || die "the GPU Node still has:
$bad"
}

cmd_join() {
  local eviction=20Gi arg server_ip version token node
  for arg; do
    case $arg in
      eviction=?*) eviction=${arg#eviction=} ;;
      *) die "unknown argument '$arg'; usage: just gpu-join [eviction=20Gi]" ;;
    esac
  done
  [[ $eviction =~ ^[0-9]+(Ki|Mi|Gi|Ti)$ ]] || die "eviction=$eviction isn't a size such as 20Gi"
  need_env HOST_LAN_IP GPU_NODE_IP GPU_NODE_SSH
  lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"
  # The GPU Node routes the Lab's subnet through this address (ADR 0002).
  [[ $HOST_LAN_IP == "$(host_lan_ip)" ]] ||
    die "HOST_LAN_IP in .env ($HOST_LAN_IP) isn't the Host's address ($(host_lan_ip)); run 'just host-wizard'"
  gpu_node_reachable ||
    die "can't log in to the GPU Node as $GPU_NODE_SSH with sudo; is it on? If it's never been set up, run 'just gpu-wizard'"

  server_ip=$(lab_server_ip)
  # The agent must match the Server exactly (ADR 0002).
  version=$(kc get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
  token=$(lab_token)

  log "Joining the GPU Node ($GPU_NODE_SSH) to the Lab"
  run_on_gpu_node "$token" join HOST_LAN_IP="$HOST_LAN_IP" SERVER_URL="https://$server_ip:6443" \
    SERVER_VERSION="$version" EVICTION="$eviction" NODE_LABEL="$GPU_NODE_LABEL" NODE_TAINT="$GPU_NODE_TAINT"

  log "Waiting for the GPU Node to be Ready"
  retry 120 gpu_node_registered || die "the GPU Node didn't register with the Lab; see 'journalctl -u k3s-agent' on it"
  kc wait --for=condition=Ready nodes -l "$GPU_NODE_LABEL_KEY" --timeout=3m >/dev/null
  log "Waiting for the Platform's DaemonSets to run on it"
  # The DaemonSet controller counts the new node a moment after it's Ready.
  sleep 2
  retry 180 daemonsets_ready || die "the Platform's DaemonSets aren't all Ready on the GPU Node; see 'kubectl --context $LAB_CONTEXT get pods -A -o wide'"
  # ArgoCD sees a DaemonSet Healthy again a few seconds after its pods are.
  kc -n argocd wait applications --all --for=jsonpath='{.status.health.status}'=Healthy --timeout=3m >/dev/null
  node=$(gpu_node_in_lab)
  log "The GPU Node is Joined as ${node%% *}"
}

cmd_leave() {
  local purge=false node=""
  case ${1:-} in
    '') ;;
    purge) purge=true ;;
    *) die "unknown argument '$1'; usage: just gpu-leave [purge]" ;;
  esac
  need_env HOST_LAN_IP GPU_NODE_IP GPU_NODE_SSH
  if lab_exists; then
    node=$(gpu_node_in_lab)
    node=${node%% *}
  fi

  if ! gpu_node_reachable; then
    if [[ -n $node ]]; then
      log "Deleting the GPU Node's Node object, $node"
      kc delete node -l "$GPU_NODE_LABEL_KEY" >/dev/null
    fi
    warn "can't reach the GPU Node as $GPU_NODE_SSH: the next 'just gpu-join' cleans it up"
    [[ $purge == false ]] || die "nothing purged on the GPU Node"
    return
  fi

  if [[ -n $node ]]; then
    log "Draining $node"
    kc drain -l "$GPU_NODE_LABEL_KEY" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s >/dev/null 2>&1 ||
      warn "$node didn't drain within 60s; its pods are stopped with the agent"
  fi
  if [[ $purge == true ]]; then run_on_gpu_node "" purge; else run_on_gpu_node "" leave; fi
  # Only once the agent is stopped, or it would register again.
  if [[ -n $node ]]; then
    log "Deleting the Node object $node"
    kc delete node -l "$GPU_NODE_LABEL_KEY" >/dev/null
  fi
  check_left "$purge"
  log "The GPU Node is Left$([[ $purge == true ]] && echo ", and purged")"
}

# The Lab's view and the machine's: a NotReady Node object means the GPU Node is off,
# unless the machine answers with its agent stopped, as after a reboot.
cmd_status() {
  local node="" machine="" line
  need_env HOST_LAN_IP GPU_NODE_IP GPU_NODE_SSH
  if gpu_node_reachable; then
    machine=$(run_on_gpu_node "" status)
  fi
  if lab_exists; then node=$(gpu_node_in_lab); fi

  if ! lab_exists; then
    echo "Lab: none"
  elif [[ -z $node ]]; then
    echo "Lab: the GPU Node is Left"
  elif [[ $node == *" True" ]]; then
    echo "Lab: the GPU Node is Joined as ${node% *}, Ready"
  elif [[ $machine == "agent: stopped"* ]]; then
    echo "Lab: the GPU Node's agent is stopped, as after a reboot, so it's Left; ${node% *} stays NotReady until 'just gpu-join'"
  else
    echo "Lab: the GPU Node is Joined as ${node% *}, NotReady: it's off"
  fi
  if [[ -n $machine ]]; then
    while read -r line; do echo "GPU Node: $line"; done <<<"$machine"
  else
    echo "GPU Node: can't log in as $GPU_NODE_SSH"
  fi
}

cmd=${1:-}
shift || true
case $cmd in
  join | leave | status) "cmd_$cmd" "$@" ;;
  *) die "usage: gpu.sh join [eviction=<size>] | leave [purge] | status" ;;
esac

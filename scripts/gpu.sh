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
# Lab's subnet and the GPU Node's address; status also gets the Lab's CA hash while a
# Lab exists (join reads it from the token).
run_on_gpu_node() {
  local input=$1 subcommand=$2 vars ca_hash
  shift 2
  vars=(LAB_SUBNET="$LAB_SUBNET" GPU_NODE_IP="$GPU_NODE_IP" "$@")
  if [[ $subcommand == status ]] && ca_hash=$(lab_ca_hash 2>/dev/null) && [[ -n $ca_hash ]]; then
    vars+=(LAB_CA_HASH="$ca_hash")
  fi
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

# Succeeds once the GPU Node is Joined, for retry.
gpu_node_joined() { gpu_node_state && [[ $GPU_NODE_STATE == joined ]]; }

# The Platform's Applications, as ArgoCD names them, separated by spaces.
platform_applications() {
  kc -n argocd get applications -l k3d-lab/group=platform -o jsonpath='{.items[*].metadata.name}'
}

# platform_daemonsets_ready <Platform Applications>: every DaemonSet of those
# Applications has a Ready, up-to-date pod on each node it should run on. Once the GPU
# Node is Ready, that means the Platform's networking, logs and metrics run there too.
# GPU Workloads are DaemonSets as well (ADR 0006), but they start in their own time,
# such as after pulling a large image, so a join never waits for them.
platform_daemonsets_ready() {
  # ArgoCD's tracking id starts with the DaemonSet's Application: <app>:apps/DaemonSet:...
  kc get daemonsets -A -o jsonpath='{range .items[*]}{.status.desiredNumberScheduled} {.status.numberReady} {.status.updatedNumberScheduled} {.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' |
    awk -v apps="$1" '
      BEGIN { for (i = split(apps, list, " "); i > 0; i--) platform[list[i]] = 1 }
      { split($4, id, ":") }
      (id[1] in platform) && ($1 != $2 || $1 != $3) { bad = 1 }
      END { exit bad }'
}

cmd_join() {
  local eviction=20Gi arg why server_ip version token apps
  for arg; do
    case $arg in
      eviction=?*) eviction=${arg#eviction=} ;;
      *) die "unknown argument '$arg'; usage: just gpu join [eviction=20Gi]" ;;
    esac
  done
  [[ $eviction =~ ^[0-9]+(Ki|Mi|Gi|Ti)$ ]] || die "eviction=$eviction isn't a size such as 20Gi"
  need_env HOST_LAN_IP GPU_NODE_IP GPU_NODE_SSH
  lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"
  # The GPU Node routes the Lab's subnet through this address (ADR 0002).
  why=$(host_lan_ip_current) || die "$why; run 'just host wizard'"
  gpu_node_reachable ||
    die "can't log in to the GPU Node as $GPU_NODE_SSH with sudo; is it on? If it's never been set up, run 'just gpu wizard'"

  server_ip=$(lab_server_ip)
  # The agent must match the Server exactly (ADR 0002).
  version=$(kc get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
  token=$(lab_token)

  log "Joining the GPU Node ($GPU_NODE_SSH) to the Lab"
  run_on_gpu_node "$token" join HOST_LAN_IP="$HOST_LAN_IP" SERVER_URL="https://$server_ip:6443" \
    SERVER_VERSION="$version" EVICTION="$eviction" NODE_LABEL="$GPU_NODE_LABEL" NODE_TAINT="$GPU_NODE_TAINT"

  log "Waiting for the GPU Node to be Ready"
  retry 120 gpu_node_joined ||
    die "the GPU Node didn't register with the Lab${GPU_NODE_ERROR:+ ($GPU_NODE_ERROR)}; see 'journalctl -u k3s-agent' on it"
  kc wait --for=condition=Ready nodes -l "$GPU_NODE_LABEL_KEY" --timeout=3m >/dev/null
  log "Waiting for the Platform's DaemonSets to run on it"
  # The DaemonSet controller counts the new node a moment after it's Ready.
  sleep 2
  apps=$(platform_applications)
  retry 180 platform_daemonsets_ready "$apps" || die "the Platform's DaemonSets aren't all Ready on the GPU Node; see 'kubectl --context $LAB_CONTEXT get pods -A -o wide'"
  # ArgoCD sees a DaemonSet Healthy again a few seconds after its pods are. Only the
  # Platform's: a GPU Workload's Application is Healthy once its pod runs, in its own time.
  kc -n argocd wait applications -l k3d-lab/group=platform --for=jsonpath='{.status.health.status}'=Healthy --timeout=3m >/dev/null
  log "The GPU Node is Joined as $GPU_NODE_NAME"
}

cmd_leave() {
  local mode=leave node="" left=true
  case ${1:-} in
    '') ;;
    purge) mode=purge ;;
    *) die "unknown argument '$1'; usage: just gpu leave [purge]" ;;
  esac
  need_env GPU_NODE_IP GPU_NODE_SSH
  if ! gpu_node_state; then
    # Deleting by label below takes whatever Node objects there are.
    warn "$GPU_NODE_ERROR"
    node="every Node object labelled $GPU_NODE_LABEL_KEY"
  elif [[ -n $GPU_NODE_NAME ]]; then
    node="the Node object $GPU_NODE_NAME"
  fi

  if ! gpu_node_reachable; then
    if [[ -n $node ]]; then
      log "Deleting $node"
      kc delete node -l "$GPU_NODE_LABEL_KEY" >/dev/null
      warn "can't reach the GPU Node as $GPU_NODE_SSH: the next 'just gpu join' cleans it up"
    else
      warn "the GPU Node isn't in the Lab, and can't be reached as $GPU_NODE_SSH to check the machine"
    fi
    [[ $mode == leave ]] || die "nothing purged on the GPU Node"
    return
  fi

  if [[ -n $node ]]; then
    log "Draining $node"
    kc drain -l "$GPU_NODE_LABEL_KEY" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s >/dev/null 2>&1 ||
      warn "couldn't drain $node within 60s; its pods are stopped with the agent"
  fi
  # gpu-node.sh fails, listing them, if anything is left that mustn't be.
  run_on_gpu_node "" "$mode" || left=false
  # Only once the agent is stopped, or it would register again.
  if [[ -n $node ]]; then
    log "Deleting $node"
    kc delete node -l "$GPU_NODE_LABEL_KEY" >/dev/null
  fi
  [[ $left == true ]] || die "the GPU Node didn't $mode cleanly (above)"
  log "The GPU Node is Left$([[ $mode == purge ]] && echo ", and purged")"
}

# The Lab's view and the machine's: the GPU Node's agent, when it answers, tells a
# rebooted GPU Node (Left) from one that's off (Joined, NotReady).
cmd_status() {
  local machine="" line
  need_env GPU_NODE_IP GPU_NODE_SSH
  if gpu_node_reachable; then
    machine=$(run_on_gpu_node "" status)
  fi
  gpu_node_state "${machine%%$'\n'*}" || die "$GPU_NODE_ERROR"

  case $GPU_NODE_STATE in
    none) echo "Lab: none" ;;
    left)
      if [[ -n $GPU_NODE_NAME ]]; then
        echo "Lab: the GPU Node's agent is stopped, as after a reboot, so it's Left; its Node object $GPU_NODE_NAME stays until 'just gpu join' or 'just gpu leave'"
      else
        echo "Lab: the GPU Node is Left"
      fi
      ;;
    joined)
      if [[ $GPU_NODE_READY == true ]]; then
        echo "Lab: the GPU Node is Joined as $GPU_NODE_NAME, Ready"
      elif [[ -n $machine ]]; then
        echo "Lab: the GPU Node is Joined as $GPU_NODE_NAME, NotReady, though its agent is running"
      else
        echo "Lab: the GPU Node is Joined as $GPU_NODE_NAME, NotReady: it's off"
      fi
      ;;
  esac
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

# The GPU Node's state in the Lab, in CONTEXT.md's terms (ADRs 0002 and 0005). Sourced
# by lib.sh, and on its own by scripts/tests/, so it sets no shell options and runs
# nothing when sourced. It reads the Lab, never the GPU Node: a caller that has logged in
# passes the first line of gpu-node.sh status.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the GPU_NODE_* variables are for the scripts that source this file

# gpu_node_state [<agent line>]: reads the Lab and sets
#   GPU_NODE_STATE  none (there's no Lab), left or joined
#   GPU_NODE_READY  true if the GPU Node is Joined and Ready, otherwise false. Joined
#                   but NotReady means it's off, unless the agent line says it runs.
#   GPU_NODE_NAME   its Node object, or empty if there's none. Set while Left, it's one
#                   left behind, as after a reboot, until 'just gpu join' or leave.
# Fails, leaving them empty and the reason in GPU_NODE_ERROR, if the Lab doesn't answer
# or more than one Node object carries the GPU Node's label.
gpu_node_state() {
  local agent=${1:-} nodes
  if ! lab_exists; then
    gpu_node_classify false "" "$agent"
    return
  fi
  if ! nodes=$(kc get nodes -l "$GPU_NODE_LABEL_KEY" --request-timeout=10s \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null); then
    GPU_NODE_STATE='' GPU_NODE_READY='' GPU_NODE_NAME=''
    GPU_NODE_ERROR="the Lab doesn't answer, so the GPU Node's state is unknown"
    return 1
  fi
  gpu_node_classify true "$nodes" "$agent"
}

# gpu_node_classify <true|false> <Node objects> [<agent line>]: the decision behind
# gpu_node_state, from whether a Lab exists and the GPU Node's Node objects there, one
# "<name> <Ready status>" line each. When the GPU Node's agent line is given, it decides
# Joined or Left, since the agent is what makes the GPU Node Left: the Ready status lags
# a stopped agent by about 40s. The Lab decides Ready and the name.
gpu_node_classify() {
  local lab=$1 nodes=$2 agent=${3:-} ready
  GPU_NODE_STATE='' GPU_NODE_READY='' GPU_NODE_NAME='' GPU_NODE_ERROR=''
  case $agent in
    '' | 'agent: running' | 'agent: stopped') ;;
    *)
      GPU_NODE_ERROR="'$agent' isn't the agent line of gpu-node.sh status"
      return 1
      ;;
  esac
  if [[ $nodes == *$'\n'* ]]; then
    GPU_NODE_ERROR="more than one Node object carries the GPU Node's label: $(cut -d' ' -f1 <<<"$nodes" | paste -sd' '); 'just gpu leave' removes them"
    return 1
  fi

  GPU_NODE_READY=false
  if [[ $lab != true ]]; then
    GPU_NODE_STATE=none
    return
  fi
  read -r GPU_NODE_NAME ready <<<"$nodes"
  if [[ -z $GPU_NODE_NAME || $agent == 'agent: stopped' ]]; then
    GPU_NODE_STATE=left
  else
    GPU_NODE_STATE=joined
    [[ $ready != True ]] || GPU_NODE_READY=true
  fi
}

# The GPU Node's state as the Lab sees it, for 'just gpu status'. Sourced by gpu.sh, and
# on its own by scripts/tests/, so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# gpu_node_lab_view <true|false> <Node object> <agent line>: the Lab line of 'just gpu
# status', from whether a Lab exists, the GPU Node's Node object there (gpu_node_in_lab's
# "<name> <Ready status>", or empty) and the first line of gpu-node.sh status (empty when
# the GPU Node can't be reached). The agent decides Joined or Left, since the Ready
# status lags a stopped agent by about 40s.
gpu_node_lab_view() {
  local lab=$1 name ready agent=$3
  read -r name ready <<<"$2"
  if [[ $lab != true ]]; then
    echo "Lab: none"
  elif [[ -z $name ]]; then
    echo "Lab: the GPU Node is Left"
  elif [[ $agent == "agent: stopped" ]]; then
    echo "Lab: the GPU Node's agent is stopped, as after a reboot, so it's Left; its Node object $name stays until 'just gpu join'"
  elif [[ $ready == True ]]; then
    echo "Lab: the GPU Node is Joined as $name, Ready"
  elif [[ -n $agent ]]; then
    echo "Lab: the GPU Node is Joined as $name, NotReady, though its agent is running"
  else
    echo "Lab: the GPU Node is Joined as $name, NotReady: it's off"
  fi
}

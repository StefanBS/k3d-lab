# The Lab's nodes: which is the Server and which the GPU Node, and waiting for them to be
# Ready. Sourced by lib.sh, and on its own by scripts/tests/, so it sets no shell options
# and runs nothing when sourced.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

# The Server's container, and its address on the Lab network.
LAB_SERVER=k3d-$LAB_NAME-server-0
lab_server_ip() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NETWORK\").IPAddress}}" "$LAB_SERVER"
}

# The GPU Node (ADRs 0002 and 0005), always found by its label, never by hostname.
GPU_NODE_LABEL_KEY=k3d-lab/gpu
GPU_NODE_LABEL=$GPU_NODE_LABEL_KEY=amd
GPU_NODE_TAINT=amd.com/gpu:NoSchedule

# A jq function: whether the node is Ready, which only a Ready condition that's True says.
NODE_READY_JQ='def ready: ([.status.conditions[]? | select(.type == "Ready")][0].status) == "True"; '

# gpu_node_object: the GPU Node's Node object in the Lab, as "<name> Ready" or "<name>
# NotReady", or nothing when there's none. The Lab alone can't say Joined or Left: after a
# reboot the GPU Node is Left, and its Node object stays NotReady until the next join.
# Fails, saying why on stderr, when the request does or there's more than one.
gpu_node_object() {
  local listed names
  listed=$(kc get nodes -o json -l "$GPU_NODE_LABEL_KEY") || {
    echo "can't read the GPU Node's Node object from the Lab" >&2
    return 1
  }
  names=$(jq -r '.items | select(length > 1) | map(.metadata.name) | join(", ")' <<<"$listed")
  if [[ -n $names ]]; then
    echo "the Lab has more than one Node object labelled $GPU_NODE_LABEL_KEY: $names; 'just gpu leave' deletes them" >&2
    return 1
  fi
  jq -r "$NODE_READY_JQ"'.items[] | "\(.metadata.name) \(if ready then "Ready" else "NotReady" end)"' <<<"$listed"
}

# nodes_unready: reads the Lab's nodes (kubectl get nodes -o json) on stdin, and prints
# "<name>: NotReady" for each whose Ready condition isn't True, which kubectl also shows
# for Unknown. A list with no nodes prints "no nodes yet", so a selector that matches
# nothing is waited out, not passed. Fails when there's nothing to read, as when the
# request failed.
nodes_unready() {
  jq -rn "$NODE_READY_JQ"'[input.items[]] as $listed |
    if ($listed | length) == 0 then "no nodes yet"
    else
      $listed[] | select(ready | not) |
      "\(.metadata.name): NotReady"
    end'
}

# wait_nodes_ready <seconds> [<kubectl get option>...]: waits until the Lab's nodes, or
# those the options select, such as -l <label>, are Ready. Gives up after that many seconds.
wait_nodes_ready() {
  local seconds=$1
  shift
  wait_until_none "$seconds" "these nodes aren't Ready" nodes_in_lab_unready "$@"
}
nodes_in_lab_unready() { kc get nodes -o json "$@" | nodes_unready; }

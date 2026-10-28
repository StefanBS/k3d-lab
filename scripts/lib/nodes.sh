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

# The GPU Node's Node object in the Lab, if it's Joined: its name and Ready status.
gpu_node_in_lab() {
  kc get nodes -l "$GPU_NODE_LABEL_KEY" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
}

# nodes_unready: reads the Lab's nodes (kubectl get nodes -o json) on stdin, and prints
# "<name>: NotReady" for each whose Ready condition isn't True, which kubectl also shows
# for Unknown. A list with no nodes prints "no nodes yet", so a selector that matches
# nothing is waited out, not passed. Fails when there's nothing to read, as when the
# request failed.
nodes_unready() {
  jq -rn '[input.items[]] as $listed |
    if ($listed | length) == 0 then "no nodes yet"
    else
      $listed[] | select(([.status.conditions[]? | select(.type == "Ready")][0].status) != "True") |
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

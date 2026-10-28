#!/usr/bin/env bats
# Waiting for the Lab's nodes to be Ready (scripts/lib/nodes.sh), without a Lab:
# wait_nodes_ready, with kc answering the Lab's nodes.

setup() {
  # shellcheck source=../lib/nodes.sh
  source "$BATS_TEST_DIRNAME/../lib/nodes.sh"
  load lab
}

# node <name> [<Ready status>]: a node as kubectl lists it, with that Ready condition, or
# none without one.
node() {
  N=$1 R=${2:-} yq -n -o json '.metadata.name = strenv(N) |
    (select(strenv(R) != "") | .status.conditions = [{"type": "MemoryPressure", "status": "False"},
      {"type": "Ready", "status": strenv(R)}]) // .'
}

# expect <pending> <node>...: what wait_nodes_ready says is still pending, while the Lab
# lists those nodes.
expect() {
  local want=$1 got
  shift
  printf '%s\n' "$@" | jq -s '{"items": .}' | kc_answers get nodes -o json
  got=$(still_pending wait_nodes_ready)
  [[ $got == "$want" ]] || {
    echo "want: $want"
    echo "got:  $got"
    return 1
  }
}

@test "every node Ready: none unready" {
  expect "" "$(node k3d-lab-server-0 True)" "$(node k3d-lab-agent-0 True)"
}

@test "a node not Ready, or Unknown: unready" {
  expect "k3d-lab-server-0: NotReady
k3d-lab-agent-0: NotReady" "$(node k3d-lab-server-0 False)" "$(node k3d-lab-agent-0 Unknown)" "$(node gpu True)"
}

@test "a node with no Ready condition yet, as just after it registers: unready" {
  expect "gpu: NotReady" "$(node gpu)"
}

@test "no nodes listed, as before the Server registers itself: pending" {
  expect "no nodes yet"
}

@test "the request failed: pending, not passed" {
  [[ $(still_pending wait_nodes_ready) == "the Lab's API isn't answering" ]]
}

@test "a selector: only the nodes it selects count" {
  node gpu False | jq -s '{"items": .}' | kc_answers get nodes -o json -l k3d-lab/gpu
  [[ $(still_pending wait_nodes_ready -l k3d-lab/gpu) == "gpu: NotReady" ]]
}

@test "still unready at the deadline: gives up, saying which" {
  node gpu False | jq -s '{"items": .}' | kc_answers get nodes -o json
  run wait_nodes_ready 30
  [[ $status -eq 1 ]]
  [[ ${lines[-2]} == "error: these nodes aren't Ready after 30 seconds:" && ${lines[-1]} == "gpu: NotReady" ]]
}

# gpu_nodes <node>...: the Lab lists those nodes under the GPU Node's label.
gpu_nodes() { printf '%s\n' "$@" | jq -s '{"items": .}' | kc_answers get nodes -o json -l k3d-lab/gpu; }

@test "the GPU Node's Node object Ready: its name and Ready" {
  gpu_nodes "$(node gpu True)"
  run gpu_node_object
  [[ $status -eq 0 ]]
  [[ $output == "gpu Ready" ]]
}

@test "the GPU Node's Node object not Ready, Unknown, or just registered: NotReady" {
  for ready in False Unknown ""; do
    gpu_nodes "$(node gpu "$ready")"
    run gpu_node_object
    [[ $status -eq 0 ]]
    [[ $output == "gpu NotReady" ]]
  done
}

@test "no GPU Node's Node object, as while it's Left: nothing" {
  gpu_nodes
  run gpu_node_object
  [[ $status -eq 0 ]]
  [[ -z $output ]]
}

@test "the request failed: fails, not Left" {
  run gpu_node_object
  [[ $status -eq 1 ]]
  [[ $output == "can't read the GPU Node's Node object from the Lab" ]]
}

@test "two Node objects labelled as the GPU Node, as after its hostname changed: fails, naming both" {
  gpu_nodes "$(node gpu True)" "$(node gpu-old False)"
  run gpu_node_object
  [[ $status -eq 2 ]]
  [[ $output == "the Lab has more than one Node object labelled k3d-lab/gpu: gpu, gpu-old; 'just gpu leave' deletes them" ]]
}

@test "replaced by a join: of two Node objects labelled as the GPU Node, the one not Ready" {
  gpu_nodes "$(node gpu True)" "$(node gpu-old False)"
  run gpu_node_replaced_objects
  [[ $status -eq 0 ]]
  [[ $output == "gpu-old" ]]
}

@test "replaced by a join: two Node objects labelled as the GPU Node, neither Ready, as before a join: both" {
  gpu_nodes "$(node gpu False)" "$(node gpu-old Unknown)"
  run gpu_node_replaced_objects
  [[ $status -eq 0 ]]
  [[ $output == "gpu
gpu-old" ]]
}

@test "replaced by a join: one Node object labelled as the GPU Node, Ready or not, or none: nothing" {
  for listed in "$(node gpu True)" "$(node gpu False)" ""; do
    if [[ -n $listed ]]; then gpu_nodes "$listed"; else gpu_nodes; fi
    run gpu_node_replaced_objects
    [[ $status -eq 0 ]]
    [[ -z $output ]]
  done
}

@test "replaced by a join: the request failed: fails, saying so" {
  run gpu_node_replaced_objects
  [[ $status -eq 1 ]]
  [[ $output == "can't read the GPU Node's Node objects from the Lab" ]]
}

@test "join's wait for the GPU Node to register: two Node objects labelled as it, pending, naming both" {
  gpu_nodes "$(node gpu True)" "$(node gpu-old False)"
  run gpu_node_unregistered
  [[ $status -eq 0 ]]
  [[ $output == "the GPU Node: the Lab has more than one Node object labelled k3d-lab/gpu: gpu, gpu-old; 'just gpu leave' deletes them" ]]
}

@test "join's wait for the GPU Node to register: no Node object labelled as it, pending; one, Ready or not: nothing" {
  gpu_nodes
  run gpu_node_unregistered
  [[ $status -eq 0 && $output == "the GPU Node: not registered yet" ]]
  for ready in True False; do
    gpu_nodes "$(node gpu "$ready")"
    run gpu_node_unregistered
    [[ $status -eq 0 && -z $output ]]
  done
}

@test "join's wait for the GPU Node to register: the request failed: fails, as a wait waits out" {
  run gpu_node_unregistered
  [[ $status -eq 1 ]]
}

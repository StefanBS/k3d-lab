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

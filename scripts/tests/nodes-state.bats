#!/usr/bin/env bats
# Which of the Lab's nodes aren't Ready yet (scripts/nodes-state.sh), without a Lab:
# nodes_unready, with the Lab's nodes on stdin.

setup() {
  # shellcheck source=../nodes-state.sh
  source "$BATS_TEST_DIRNAME/../nodes-state.sh"
}

# node <name> [<Ready status>]: a node as kubectl lists it, with that Ready condition, or
# none without one.
node() {
  N=$1 R=${2:-} yq -n -o json '.metadata.name = strenv(N) |
    (select(strenv(R) != "") | .status.conditions = [{"type": "MemoryPressure", "status": "False"},
      {"type": "Ready", "status": strenv(R)}]) // .'
}

# expect <output> <node>...: nodes_unready's output for a list of those nodes.
expect() {
  local want=$1 got
  shift
  got=$(printf '%s\n' "$@" | jq -s '{"items": .}' | nodes_unready)
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

@test "no nodes to read, as when the request failed: fails" {
  run nodes_unready <<<""
  [[ $status -ne 0 ]]
}

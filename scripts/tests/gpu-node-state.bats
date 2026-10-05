#!/usr/bin/env bats
# The GPU Node's state (scripts/gpu-node-state.sh), without a Lab or a GPU Node: the
# decision table, then the reader with lab_exists and kc stubbed. Each test calls the
# functions directly, not through bats' run, which would lose the globals they set.

setup() {
  # shellcheck source=../gpu-node-state.sh
  source "$BATS_TEST_DIRNAME/../gpu-node-state.sh"
}

# expect <state> <ready> <name>: the globals the last call set.
expect() {
  [[ $GPU_NODE_STATE == "$1" && $GPU_NODE_READY == "$2" && $GPU_NODE_NAME == "$3" ]] || {
    echo "want: $1 $2 '$3'"
    echo "got:  $GPU_NODE_STATE $GPU_NODE_READY '$GPU_NODE_NAME' ${GPU_NODE_ERROR:+(error: $GPU_NODE_ERROR)}"
    return 1
  }
}

# fails <command>...: the command must fail. Not `! command`, which set -e ignores, so
# the test would pass either way.
fails() {
  if "$@"; then
    echo "succeeded: $*"
    return 1
  fi
}

@test "no Lab: none, whatever the agent says" {
  gpu_node_classify false ""
  expect none false ""
  gpu_node_classify false "" "agent: running"
  expect none false ""
}

@test "no Node object: Left" {
  gpu_node_classify true ""
  expect left false ""
  gpu_node_classify true "" "agent: stopped"
  expect left false ""
}

@test "no Node object, agent running: Left, not registered with this Lab" {
  gpu_node_classify true "" "agent: running"
  expect left false ""
}

@test "Ready: Joined and Ready" {
  gpu_node_classify true "gpu True"
  expect joined true gpu
  gpu_node_classify true "gpu True" "agent: running"
  expect joined true gpu
}

@test "NotReady, without the agent line: Joined, off" {
  gpu_node_classify true "gpu False"
  expect joined false gpu
  gpu_node_classify true "gpu Unknown"
  expect joined false gpu
}

@test "NotReady, agent running: Joined, NotReady" {
  gpu_node_classify true "gpu False" "agent: running"
  expect joined false gpu
}

@test "no Ready condition yet: Joined, NotReady" {
  gpu_node_classify true "gpu "
  expect joined false gpu
}

@test "NotReady, agent stopped: Left, rebooted, its Node object left behind" {
  gpu_node_classify true "gpu False" "agent: stopped"
  expect left false gpu
}

@test "Ready, agent stopped: Left, since the Ready status lags the agent" {
  gpu_node_classify true "gpu True" "agent: stopped"
  expect left false gpu
}

@test "two Node objects: fails, naming both" {
  fails gpu_node_classify true $'gpu True\ngpu-old False'
  expect "" "" ""
  [[ $GPU_NODE_ERROR == *"gpu gpu-old"* ]]
}

@test "an agent line gpu-node.sh never prints: fails" {
  fails gpu_node_classify true "gpu True" "agent: unknown"
  expect "" "" ""
}

@test "a failure clears what an earlier call set" {
  gpu_node_classify true "gpu True"
  fails gpu_node_classify true $'a True\nb True'
  expect "" "" ""
}

@test "reader: no Lab" {
  lab_exists() { return 1; }
  gpu_node_state
  expect none false ""
}

@test "reader: passes the Lab's Node objects and the agent line on" {
  lab_exists() { return 0; }
  kc() { printf 'gpu False\n'; }
  gpu_node_state "agent: stopped"
  expect left false gpu
}

@test "reader: the Lab doesn't answer" {
  lab_exists() { return 0; }
  kc() { return 1; }
  fails gpu_node_state
  expect "" "" ""
  [[ $GPU_NODE_ERROR == *"doesn't answer"* ]]
}

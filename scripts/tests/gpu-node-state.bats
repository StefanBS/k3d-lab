#!/usr/bin/env bats
# The Lab line of 'just gpu status' (scripts/gpu-node-state.sh), without a Lab or a GPU
# Node: gpu_node_lab_view <Lab exists> <Node object> <agent line>.

setup() {
  # shellcheck source=../gpu-node-state.sh
  source "$BATS_TEST_DIRNAME/../gpu-node-state.sh"
}

# expect <line> <arguments>...: gpu_node_lab_view prints that line for those arguments.
expect() {
  local want=$1 got
  shift
  got=$(gpu_node_lab_view "$@")
  [[ $got == "$want" ]] || {
    echo "for:  $*"
    echo "want: $want"
    echo "got:  $got"
    return 1
  }
}

@test "no Lab" {
  expect "Lab: none" false "" ""
}

@test "no Node object: Left, whatever the agent says" {
  expect "Lab: the GPU Node is Left" true "" ""
  expect "Lab: the GPU Node is Left" true "" "agent: stopped"
  expect "Lab: the GPU Node is Left" true "" "agent: running"
}

@test "Ready: Joined, Ready" {
  expect "Lab: the GPU Node is Joined as gpu, Ready" true "gpu True" ""
  expect "Lab: the GPU Node is Joined as gpu, Ready" true "gpu True" "agent: running"
}

@test "NotReady, and the GPU Node can't be reached: Joined, off" {
  expect "Lab: the GPU Node is Joined as gpu, NotReady: it's off" true "gpu False" ""
  expect "Lab: the GPU Node is Joined as gpu, NotReady: it's off" true "gpu Unknown" ""
}

@test "NotReady, agent running: Joined, not off" {
  expect "Lab: the GPU Node is Joined as gpu, NotReady, though its agent is running" true "gpu False" "agent: running"
}

@test "agent stopped: Left, even while the Lab still says Ready" {
  local left="Lab: the GPU Node's agent is stopped, as after a reboot, so it's Left; its Node object gpu stays until 'just gpu join'"
  expect "$left" true "gpu False" "agent: stopped"
  expect "$left" true "gpu True" "agent: stopped"
}

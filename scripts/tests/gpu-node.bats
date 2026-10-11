#!/usr/bin/env bats
# What scripts/gpu-node.sh reads from a command's output, without a GPU Node: each
# command is a stub that answers as the real one would. The script is sourced in a bash
# of its own, since it sets the shell options it runs under, pipefail among them.

setup() {
  # Stubs that print one line at a time, pausing between them: a reader that stops at
  # its first match closes the pipe before the next line is written, and the stub dies
  # of that write, with 141, as the real command does on a long answer.
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/lines" <<'STUB'
#!/usr/bin/env bash
[[ -f $ANSWER ]] || exit 1
while IFS= read -r line; do
  echo "$line" 2>/dev/null || exit 141
  sleep 0.2
done <"$ANSWER"
STUB
  cat >"$BATS_TEST_TMPDIR/bin/iptables-restore" <<'STUB'
#!/usr/bin/env bash
cat >"$RESTORED"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  ln -s lines "$BATS_TEST_TMPDIR/bin/iptables-save"
  ln -s lines "$BATS_TEST_TMPDIR/bin/ctr"
  PATH=$BATS_TEST_TMPDIR/bin:$PATH
  export ANSWER=$BATS_TEST_TMPDIR/answer RESTORED=$BATS_TEST_TMPDIR/restored
}

# gpu_node <function> <argument>...: runs one of the script's functions.
gpu_node() {
  run bash -c 'source "$1"; shift; "$@"' gpu-node "$BATS_TEST_DIRNAME/../gpu-node.sh" "$@"
}

@test "a table with Cilium's rules, the first of them early: restored without them (#163)" {
  cat >"$ANSWER" <<'RULES'
*filter
:INPUT ACCEPT [0:0]
:CILIUM_INPUT - [0:0]
:DOCKER - [0:0]
-A INPUT -j CILIUM_INPUT
-A INPUT -j DOCKER
COMMIT
RULES
  gpu_node clean_cilium_table iptables-save iptables-restore filter
  [[ $status -eq 0 ]]
  [[ $(<"$RESTORED") == $'*filter\n:INPUT ACCEPT [0:0]\n:DOCKER - [0:0]\n-A INPUT -j DOCKER\nCOMMIT' ]]
}

@test "a table without Cilium's rules: left as it is" {
  printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '-A INPUT -j DOCKER' COMMIT >"$ANSWER"
  gpu_node clean_cilium_table iptables-save iptables-restore filter
  [[ $status -eq 0 && ! -e $RESTORED ]]
}

@test "a table that can't be saved, as one the kernel doesn't have: left as it is" {
  gpu_node clean_cilium_table iptables-save iptables-restore raw
  [[ $status -eq 0 && ! -e $RESTORED ]]
}

@test "an image in a long image store, not the last of it: present (#163)" {
  printf '%s\n' docker.io/library/a:1 docker.io/rocm/pytorch@sha256:abc docker.io/library/b:1 docker.io/library/c:1 >"$ANSWER"
  gpu_node image_present docker.io/rocm/pytorch@sha256:abc ctr -n k8s.io
  [[ $status -eq 0 ]]
}

@test "an image that's only the start of another's name: not present" {
  printf '%s\n' docker.io/rocm/pytorch@sha256:abcdef docker.io/library/b:1 >"$ANSWER"
  gpu_node image_present docker.io/rocm/pytorch@sha256:abc ctr -n k8s.io
  [[ $status -eq 1 ]]
}

@test "an image store that can't be listed: not present" {
  gpu_node image_present docker.io/rocm/pytorch@sha256:abc ctr -n k8s.io
  [[ $status -eq 1 ]]
}

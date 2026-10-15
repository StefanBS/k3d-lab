#!/usr/bin/env bats
# How the scripts wait for the Lab (scripts/lib/wait.sh), without a Lab: wait_until_none
# with a scripted command, and how it logs what's pending.

setup() {
  # shellcheck source=../lib/wait.sh
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  load lab
  answers=$BATS_TEST_TMPDIR/answers
}

# answers <answer>...: what pending prints on each call, one argument per call: "fail"
# makes it fail without printing, "" prints nothing. The last answer repeats.
answers() { printf '%s\n' "$@" | sed 's/^$/<none>/' >"$answers"; }
pending() {
  local answer
  answer=$(head -1 "$answers")
  (($(wc -l <"$answers") == 1)) || sed -i 1d "$answers"
  case $answer in
    fail) return 1 ;;
    '<none>') ;;
    *) printf '%b\n' "$answer" ;;
  esac
}

@test "nothing pending: returns at once, saying nothing" {
  answers ""
  run wait_until_none 60 "late" pending
  [[ $status -eq 0 && -z $output ]]
}

@test "pending, then nothing: logs what's pending once, then returns" {
  answers "a: OutOfSync, Healthy" "a: OutOfSync, Healthy" ""
  run wait_until_none 60 "late" pending
  [[ $status -eq 0 && $output == "==> Still waiting: OutOfSync, Healthy: a" ]]
}

@test "a failed command is not yet, also when it printed nothing" {
  answers fail ""
  run wait_until_none 60 "late" pending
  [[ $status -eq 0 && $output == "==> Still waiting: the Lab's API isn't answering" ]]
}

@test "logs again whenever what's pending changes" {
  answers "a: OutOfSync, Healthy\nb: OutOfSync, Healthy" "b: Synced, Progressing" ""
  run wait_until_none 60 "late" pending
  [[ $status -eq 0 && $output == "==> Still waiting: OutOfSync, Healthy: a b
==> Still waiting: Synced, Progressing: b" ]]
}

@test "still pending at the deadline: dies with what's pending, in full" {
  answers "a: OutOfSync, Healthy\nb: Synced, Progressing"
  run wait_until_none 120 "these Applications aren't Settled" pending
  [[ $status -eq 1 && $output == "==> Still waiting: OutOfSync, Healthy: a; Synced, Progressing: b
error: these Applications aren't Settled after 2 minutes:
a: OutOfSync, Healthy
b: Synced, Progressing" ]]
}

@test "the summary groups lines by why, in the order each first appears" {
  run wait_summary <<<"a: OutOfSync, Healthy
b: synced at 0123456
c: OutOfSync, Healthy"
  [[ $output == "OutOfSync, Healthy: a c; synced at 0123456: b" ]]
}

@test "the summary logs a line without a name as it is" {
  run wait_summary <<<"the Lab's API isn't answering"
  [[ $output == "the Lab's API isn't answering" ]]
}

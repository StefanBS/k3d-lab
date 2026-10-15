#!/usr/bin/env bats
# Which of the Lab's ApplicationSets haven't generated their Applications yet
# (scripts/lib/applicationsets.sh), without a Lab: applicationsets_pending, with the
# Lab's ApplicationSets on stdin.

setup() {
  # shellcheck source=../lib/applicationsets.sh
  source "$BATS_TEST_DIRNAME/../lib/applicationsets.sh"
}

# applicationset <name> [<ResourcesUpToDate status> [<reason>]]: an ApplicationSet as
# kubectl lists it, with that condition, or none without one.
applicationset() {
  N=$1 S=${2:-} R=${3:-} yq -n -o json '.metadata.name = strenv(N) |
    (select(strenv(S) != "") | .status.conditions = [{"type": "ErrorOccurred", "status": "False"},
      {"type": "ResourcesUpToDate", "status": strenv(S), "reason": strenv(R)}]) // .'
}

# expect <output> [<name>...] -- <ApplicationSet>...: applicationsets_pending's output for
# those names, and a list of those ApplicationSets.
expect() {
  local want=$1 got names=()
  shift
  while [[ $1 != -- ]]; do
    names+=("$1")
    shift
  done
  shift
  got=$(printf '%s\n' "$@" | jq -s '{"items": .}' | applicationsets_pending "${names[@]}")
  [[ $got == "$want" ]] || {
    echo "want: $want"
    echo "got:  $got"
    return 1
  }
}

@test "every ApplicationSet ResourcesUpToDate: none pending" {
  expect "" -- "$(applicationset platform True)" "$(applicationset workloads True)"
}

@test "not ResourcesUpToDate, or not yet reconciled: pending" {
  expect "platform: not ResourcesUpToDate (ErrorOccurred)
workloads: not ResourcesUpToDate" -- \
    "$(applicationset platform False ErrorOccurred)" "$(applicationset workloads)" "$(applicationset demos True)"
}

@test "named: only those count, and one not created yet is pending, in the order named" {
  expect "workloads: not created yet
demos: not ResourcesUpToDate" platform workloads demos -- \
    "$(applicationset demos Unknown)" "$(applicationset platform True)" "$(applicationset other False)"
}

@test "none listed, before the root Application creates them: pending" {
  expect "no ApplicationSets yet" --
}

@test "no ApplicationSets to read, as when the request failed: fails" {
  run applicationsets_pending platform <<<""
  [[ $status -ne 0 ]]
}

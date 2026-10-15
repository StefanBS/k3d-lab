#!/usr/bin/env bats
# Waiting for the Lab's ApplicationSets to generate their Applications, and refreshing
# them (scripts/lib/applicationsets.sh), without a Lab: kc answers for the Lab.

setup() {
  # shellcheck source=../lib/applicationsets.sh
  source "$BATS_TEST_DIRNAME/../lib/applicationsets.sh"
  load lab
}

# applicationset <name> [<ResourcesUpToDate status> [<reason>]]: an ApplicationSet as
# kubectl lists it, with that condition, or none without one.
applicationset() {
  N=$1 S=${2:-} R=${3:-} yq -n -o json '.metadata.name = strenv(N) |
    (select(strenv(S) != "") | .status.conditions = [{"type": "ErrorOccurred", "status": "False"},
      {"type": "ResourcesUpToDate", "status": strenv(S), "reason": strenv(R)}]) // .'
}

# expect <pending> [<name>...] -- <ApplicationSet>...: what wait_applicationsets says is
# still pending for those names, while the Lab lists those ApplicationSets.
expect() {
  local want=$1 got names=()
  shift
  while [[ $1 != -- ]]; do
    names+=("$1")
    shift
  done
  shift
  printf '%s\n' "$@" | jq -s '{"items": .}' | kc_answers -n argocd get applicationsets -o json
  got=$(still_pending wait_applicationsets "${names[@]}")
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

@test "the request failed: pending, not passed" {
  [[ $(still_pending wait_applicationsets platform) == "the Lab's API isn't answering" ]]
}

# What the controller still has to take, as refresh_applicationsets asks for it.
REFRESHES=(-n argocd get applicationsets
  -o 'jsonpath={.items[*].metadata.annotations.argocd\.argoproj\.io/application-set-refresh}')
ASK=(-n argocd annotate applicationsets --all argocd.argoproj.io/application-set-refresh=true --overwrite)

@test "refresh: asks every ApplicationSet, and passes once the controller has taken them all" {
  kc_succeeds "${ASK[@]}"
  kc_succeeds "${REFRESHES[@]}"
  run refresh_applicationsets 300
  [[ $status -eq 0 ]]
  [[ $(head -n 1 "$KC_CALLS") == "${ASK[*]}" ]]
}

@test "refresh: a refresh never taken, or a request that fails, gives up" {
  kc_succeeds "${ASK[@]}"
  kc_answers "${REFRESHES[@]}" <<<"true true"
  run refresh_applicationsets 120
  [[ $status -eq 1 && $output == "error: the ApplicationSets haven't refreshed after 2 minutes" ]]
  rm "$KC_ANSWERS/$(kc_key "${REFRESHES[@]}")"
  run refresh_applicationsets 120
  [[ $status -eq 1 && $output == "error: the ApplicationSets haven't refreshed after 2 minutes" ]]
}

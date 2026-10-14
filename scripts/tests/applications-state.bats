#!/usr/bin/env bats
# Which of the Lab's Applications aren't Settled yet (scripts/applications-state.sh),
# without a Lab: applications_unsettled, with the Lab's Applications on stdin.

setup() {
  # shellcheck source=../applications-state.sh
  source "$BATS_TEST_DIRNAME/../applications-state.sh"
}

repo=https://github.com/StefanBS/k3d-lab.git
commit=58f6f579d5fc05783fa2f7db28fd3c72d7e15ecb

# application <name> <sync> <health> <revisions> <repoURLs> [<compared to>] [<group>]: an
# Application as ArgoCD lists it, with one source per repoURL, each tracking the branch
# "track", and its synced revisions (comma-separated). One repoURL makes a single-source
# Application. ArgoCD last compared it with its sources tracking <compared to>, by
# default "track" too. It's in the platform group unless another is given.
application() {
  local name=$1 sync=$2 health=$3 revisions=$4 urls=$5 compared=${6:-track} group=${7:-platform}
  N=$name S=$sync H=$health R=$revisions U=$urls C=$compared G=$group yq -n -o json '
    (strenv(U) | split(",") | map({"repoURL": ., "targetRevision": "track"})) as $sources |
    (strenv(U) | split(",") | map({"repoURL": ., "targetRevision": strenv(C)})) as $compared |
    (strenv(R) | split(",")) as $revisions |
    .metadata.name = strenv(N) |
    .metadata.labels."k3d-lab/group" = strenv(G) |
    .status.sync.status = strenv(S) |
    .status.health.status = strenv(H) |
    (select(($sources | length) == 1) | .spec.source = $sources[0] | .status.sync.revision = $revisions[0] |
      .status.sync.comparedTo.source = $compared[0]) //
    (.spec.sources = $sources | .status.sync.revisions = $revisions | .status.sync.comparedTo.sources = $compared)'
}

# settled <name>: an Application that's Synced and Healthy at the commit.
settled() { application "$1" Synced Healthy "$commit" "$repo"; }

# expect <output> <options>... -- <Application>...: applications_unsettled's output with
# those options, for a list of those Applications.
expect() {
  local want=$1 got options=()
  shift
  while [[ $1 != -- ]]; do
    options+=("$1")
    shift
  done
  shift
  got=$(printf '%s\n' "$@" | jq -s '{"items": .}' | applications_unsettled "${options[@]}")
  [[ $got == "$want" ]] || {
    echo "want: $want"
    echo "got:  $got"
    return 1
  }
}

@test "every Application synced and healthy at the commit: none unsettled" {
  expect "" --at "$repo" "$commit" -- \
    "$(settled root)" \
    "$(application cilium Synced Healthy "1.20.2,$commit" "https://helm.cilium.io,$repo")"
}

@test "synced at another commit of the repo: unsettled" {
  expect "cilium: synced at 0123456" --at "$repo" "$commit" -- \
    "$(settled root)" \
    "$(application cilium Synced Healthy "1.20.2,0123456789" "https://helm.cilium.io,$repo")"
}

@test "not synced, or not healthy: unsettled" {
  expect "root: OutOfSync, Healthy
cilium: Synced, Progressing" -- \
    "$(application root OutOfSync Healthy "$commit" "$repo")" \
    "$(application cilium Synced Progressing "1.20.2,$commit" "https://helm.cilium.io,$repo")"
}

@test "never compared, as when the branch it tracked is gone: unsettled" {
  expect "root: Unknown, Healthy" --at "$repo" "$commit" -- "$(application root Unknown Healthy "" "$repo")"
}

@test "synced, but at no revision of the repo: unsettled" {
  expect "cilium: synced at no revision" --at "$repo" "$commit" -- \
    "$(application cilium Synced Healthy "1.20.2" "https://helm.cilium.io,$repo")"
}

@test "synced at the commit, but compared before it tracked the branch: unsettled" {
  expect "cilium: compared with main" --at "$repo" "$commit" -- \
    "$(application cilium Synced Healthy "1.20.2,$commit" "https://helm.cilium.io,$repo" main)"
}

@test "without --at, synced at another commit is Settled" {
  expect "" -- "$(application cilium Synced Healthy "1.20.2,0123456789" "https://helm.cilium.io,$repo")"
}

@test "with no status yet: unsettled, with its state Unknown" {
  expect "grafana: Unknown, Unknown" -- '{"metadata": {"name": "grafana"}}'
}

@test "with an empty status, as before ArgoCD first compares it: unsettled, with its state Unknown" {
  expect "grafana: Unknown, Unknown" -- '{"metadata": {"name": "grafana"}, "status": {"sync": {"status": ""}}}'
}

@test "named: only those count" {
  expect "rollouts-demo: Synced, Progressing" rollouts-demo -- \
    "$(application root OutOfSync Healthy "$commit" "$repo")" \
    "$(application rollouts-demo Synced Progressing "$commit" "$repo")"
}

@test "named, before its Application is generated: not generated yet, in the order named" {
  expect "rollouts-demo: not generated yet
third-demo: not generated yet" rollouts-demo other-demo third-demo -- \
    "$(settled root)" "$(settled other-demo)"
}

@test "a group: only its Applications count" {
  expect "rollouts-demo: Synced, Progressing" --group workloads -- \
    "$(application cilium OutOfSync Healthy "$commit" "$repo")" \
    "$(application rollouts-demo Synced Progressing "$commit" "$repo" track workloads)"
}

@test "gone, while a named Application is still listed: still there" {
  expect "rollouts-demo: still there" --gone rollouts-demo -- "$(settled root)" "$(settled rollouts-demo)"
}

@test "gone, once the named Applications are no longer listed: none" {
  expect "" --gone rollouts-demo -- "$(settled root)"
}

@test "no Applications to read, as when the request failed: fails" {
  run applications_unsettled --gone rollouts-demo <<<""
  [[ $status -ne 0 ]]
}

#!/usr/bin/env bats
# Which Applications haven't caught up with 'just track' yet (scripts/track-state.sh),
# without a Lab: apps_behind <repo> <commit>, with the Lab's Applications on stdin.

setup() {
  # shellcheck source=../track-state.sh
  source "$BATS_TEST_DIRNAME/../track-state.sh"
}

repo=https://github.com/StefanBS/k3d-lab.git
commit=58f6f579d5fc05783fa2f7db28fd3c72d7e15ecb

# app <name> <sync> <health> <revisions> <repoURLs>: an Application as ArgoCD lists it,
# with one source per repoURL and its synced revisions (comma-separated). One repoURL
# makes a single-source Application.
app() {
  local name=$1 sync=$2 health=$3 revisions=$4 urls=$5
  N=$name S=$sync H=$health R=$revisions U=$urls yq -n -o json '
    (strenv(U) | split(",") | map({"repoURL": .})) as $sources |
    (strenv(R) | split(",")) as $revisions |
    .metadata.name = strenv(N) |
    .status.sync.status = strenv(S) |
    .status.health.status = strenv(H) |
    (select(($sources | length) == 1) | .spec.source = $sources[0] | .status.sync.revision = $revisions[0]) //
    (.spec.sources = $sources | .status.sync.revisions = $revisions)'
}

# behind <Application>...: apps_behind's output for a list of those Applications.
behind() {
  printf '%s\n' "$@" | yq -p json -o json ea '{"items": [.]}' | apps_behind "$repo" "$commit"
}

# expect <output> <Application>...
expect() {
  local want=$1 got
  shift
  got=$(behind "$@")
  [[ $got == "$want" ]] || {
    echo "want: $want"
    echo "got:  $got"
    return 1
  }
}

@test "every Application synced and healthy at the commit: none behind" {
  expect "" \
    "$(app root Synced Healthy "$commit" "$repo")" \
    "$(app cilium Synced Healthy "1.20.2,$commit" "https://helm.cilium.io,$repo")"
}

@test "synced at another commit of the repo: behind" {
  expect "cilium: synced at 0123456" \
    "$(app root Synced Healthy "$commit" "$repo")" \
    "$(app cilium Synced Healthy "1.20.2,0123456789" "https://helm.cilium.io,$repo")"
}

@test "not synced, or not healthy: behind" {
  expect "root: OutOfSync, Healthy
cilium: Synced, Progressing" \
    "$(app root OutOfSync Healthy "$commit" "$repo")" \
    "$(app cilium Synced Progressing "1.20.2,$commit" "https://helm.cilium.io,$repo")"
}

@test "never compared, as when the branch it tracked is gone: behind" {
  expect "root: Unknown, Healthy" "$(app root Unknown Healthy "" "$repo")"
}

@test "synced, but at no revision of the repo: behind" {
  expect "cilium: synced at no revision" \
    "$(app cilium Synced Healthy "1.20.2" "https://helm.cilium.io,$repo")"
}

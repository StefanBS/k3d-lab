#!/usr/bin/env bats
# Waiting for the Lab's Applications to be Settled, and refreshing them
# (scripts/lib/applications.sh), without a Lab: kc answers for the Lab.

setup() {
  # shellcheck source=../lib/applications.sh
  source "$BATS_TEST_DIRNAME/../lib/applications.sh"
  load lab
  repo=$LAB_REPO
}

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

# expect <pending> <option>... -- <Application>...: what wait_settled says is still pending
# with those options, while the Lab lists those Applications.
expect() {
  local want=$1 got options=()
  shift
  while [[ $1 != -- ]]; do
    options+=("$1")
    shift
  done
  shift
  printf '%s\n' "$@" | jq -s '{"items": .}' | kc_answers -n argocd get applications -o json
  got=$(still_pending wait_settled "${options[@]}")
  [[ $got == "$want" ]] || {
    echo "want: $want"
    echo "got:  $got"
    return 1
  }
}

@test "every Application synced and healthy at the commit: none unsettled" {
  expect "" --at "$commit" -- \
    "$(settled root)" \
    "$(application cilium Synced Healthy "1.20.2,$commit" "https://helm.cilium.io,$repo")"
}

@test "synced at another commit of the repo: unsettled" {
  expect "cilium: synced at 0123456" --at "$commit" -- \
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
  expect "root: Unknown, Healthy" --at "$commit" -- "$(application root Unknown Healthy "" "$repo")"
}

@test "synced, but at no revision of the repo: unsettled" {
  expect "cilium: synced at no revision" --at "$commit" -- \
    "$(application cilium Synced Healthy "1.20.2" "https://helm.cilium.io,$repo")"
}

@test "synced at the commit, but compared before it tracked the branch: unsettled" {
  expect "cilium: compared with main" --at "$commit" -- \
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

@test "the request failed: pending, not passed, also when waiting for Applications to go" {
  [[ $(still_pending wait_settled --gone rollouts-demo) == "the Lab's API isn't answering" ]]
  [[ $(still_pending wait_settled) == "the Lab's API isn't answering" ]]
}

@test "still unsettled, or not gone, at the deadline: gives up, saying which" {
  settled rollouts-demo | jq -s '{"items": .}' | kc_answers -n argocd get applications -o json
  run wait_settled 60 --gone rollouts-demo
  [[ $status -eq 1 ]]
  [[ ${lines[-2]} == "error: these Applications aren't gone after 1 minutes:" ]]
  [[ ${lines[-1]} == "rollouts-demo: still there" ]]
  application root OutOfSync Healthy "$commit" "$repo" | jq -s '{"items": .}' |
    kc_answers -n argocd get applications -o json
  run wait_settled 0 root
  [[ $status -eq 1 && ${lines[-2]} == "error: these Applications aren't Settled after 0 minutes:" ]]
}

@test "refresh: every Application without names, only those named with them" {
  kc_succeeds -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite
  kc_succeeds -n argocd annotate applications comfyui cilium argocd.argoproj.io/refresh=hard --overwrite
  refresh_applications
  refresh_applications comfyui cilium
  [[ $(cat "$KC_CALLS") == "-n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite
-n argocd annotate applications comfyui cilium argocd.argoproj.io/refresh=hard --overwrite" ]]
}

@test "refresh: a request that fails fails" {
  run refresh_applications comfyui
  [[ $status -ne 0 ]]
}

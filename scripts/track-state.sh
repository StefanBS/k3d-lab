# Whether the Lab's Applications have caught up with 'just track'. Sourced by track.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# applications_behind <repo> <commit>: reads the Lab's Applications (kubectl get
# applications -o json) on stdin, and prints a line for each that isn't yet Synced and
# Healthy at that commit of the repo, saying why. A status alone isn't enough: until
# ArgoCD compares an Application again, it still says Synced at the revision it tracked
# before. Nor is the commit, when the branch it now tracks is at the one it synced:
# ArgoCD must also have compared it with the branch it now tracks.
applications_behind() {
  # shellcheck disable=SC2016 # $sources, $compared and $revisions are yq's, not the shell's.
  REPO=$1 COMMIT=$2 yq -p json -o tsv '
    .items[] |
    (.spec.sources // [.spec.source]) as $sources |
    (.status.sync.comparedTo.sources // [.status.sync.comparedTo.source]) as $compared |
    (.status.sync.revisions // [.status.sync.revision]) as $revisions |
    # The sources from REPO: the branch each tracks, the one ArgoCD last compared it with,
    # and the commit it synced.
    [$sources | to_entries | .[] | select(.value.repoURL == strenv(REPO)) | .key as $i |
      {"tracks": .value.targetRevision, "compared": ($compared[$i].targetRevision // "nothing"),
        "synced": ($revisions[$i] // "")}] as $ours |
    (.status.sync.status // "Unknown") as $sync |
    (.status.health.status // "Unknown") as $health |
    [$ours[] | select(.compared != .tracks) | .compared] as $stale |
    [$ours[] | select(.synced != strenv(COMMIT)) | .synced] as $elsewhere |
    # The first reason that applies, if any. Each starts from the name: in yq, a bare
    # string is output even when the select before it outputs nothing.
    [
      (select(($sync != "Synced") or ($health != "Healthy")) | .metadata.name + ": " + $sync + ", " + $health),
      (select(($stale | length) > 0) | .metadata.name + ": compared with " + $stale[0]),
      (select(($elsewhere | length) > 0 and $elsewhere[0] == "") | .metadata.name + ": synced at no revision"),
      (select(($elsewhere | length) > 0 and $elsewhere[0] != "") |
        .metadata.name + ": synced at " + ($elsewhere[0] | sub("^(.{7}).*", "${1}")))
    ] | select(length > 0) | .[0]'
}

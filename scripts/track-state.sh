# Whether the Lab's Applications have caught up with 'just track'. Sourced by track.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# apps_behind <repo> <commit>: reads the Lab's Applications (kubectl get applications
# -o json) on stdin, and prints a line for each that isn't yet Synced and Healthy at that
# commit of the repo, saying why. A status alone isn't enough: until ArgoCD compares an
# Application again, it still says Synced at the revision it tracked before.
apps_behind() {
  # shellcheck disable=SC2016 # $sources and $revisions are yq's, not the shell's.
  REPO=$1 COMMIT=$2 yq -p json -o tsv '
    .items[] |
    (.spec.sources // [.spec.source]) as $sources |
    (.status.sync.revisions // [.status.sync.revision]) as $revisions |
    [
      .metadata.name,
      .status.sync.status // "Unknown",
      .status.health.status // "Unknown",
      ([$sources | to_entries | .[] | select(.value.repoURL == strenv(REPO)) | $revisions[.key] // "none"] |
        map(select(. != strenv(COMMIT))) | .[0] // "")
    ]' | while IFS=$'\t' read -r name sync health stale; do
    if [[ $sync != Synced || $health != Healthy ]]; then
      echo "$name: $sync, $health"
    elif [[ -n $stale ]]; then
      if [[ $stale == none ]]; then
        echo "$name: synced at no revision"
      else
        echo "$name: synced at ${stale:0:7}"
      fi
    fi
  done
}

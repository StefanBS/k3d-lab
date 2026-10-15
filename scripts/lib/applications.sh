# Which of the Lab's Applications aren't Settled yet. Sourced by lib.sh, whose
# wait_settled waits on it, and on its own by scripts/tests/, so it sets no shell options
# and runs nothing when sourced.
# shellcheck shell=bash

# applications_unsettled [--at <repo> <commit>] [--group <group>] [--gone] [<name>...]:
# reads the Lab's Applications (kubectl get applications -o json) on stdin, and prints a
# line for each that isn't Settled, as "<name>: <why>". Without names, every Application
# listed counts; with them, only those, and one not listed yet is "not generated yet".
#   --at     It must also be synced at that commit of the repo. A status alone isn't
#            enough: until ArgoCD compares an Application again, it still says Synced at
#            the revision it tracked before. Nor is the commit, when the branch it now
#            tracks is at the one it synced: ArgoCD must also have compared it with the
#            branch it now tracks.
#   --group  Only the Applications of that group, platform or workloads.
#   --gone   Instead, prints "<name>: still there" for each named one that's still listed.
# Fails when there's nothing to read, as when the request failed.
applications_unsettled() {
  local repo='' commit='' group='' gone=false
  while (($#)); do
    case $1 in
      --at)
        repo=$2 commit=$3
        shift 3
        ;;
      --group)
        group=$2
        shift 2
        ;;
      --gone)
        gone=true
        shift
        ;;
      *) break ;;
    esac
  done
  # shellcheck disable=SC2016 # The $ names are jq variables, not the shell's.
  jq -rn --arg repo "$repo" --arg commit "$commit" --arg group "$group" --argjson gone "$gone" '
    # Why the Application on input is not Settled, or nothing if it is: the first reason
    # that applies.
    def why:
      (.spec.sources // [.spec.source]) as $sources |
      (.status.sync.comparedTo.sources // [.status.sync.comparedTo.source]) as $compared |
      (.status.sync.revisions // [.status.sync.revision]) as $revisions |
      # The sources from the repo: the branch each tracks, the one ArgoCD last compared it
      # with, and the commit it synced.
      [$sources | to_entries[] | select($commit != "" and .value.repoURL == $repo) | .key as $i |
        {tracks: .value.targetRevision, compared: ($compared[$i].targetRevision // "nothing"),
          synced: ($revisions[$i] // "")}] as $ours |
      # Before its first comparison, ArgoCD gives an Application an empty status, not none.
      (.status.sync.status // "" | if . == "" then "Unknown" end) as $sync |
      (.status.health.status // "" | if . == "" then "Unknown" end) as $health |
      [$ours[] | select(.compared != .tracks) | .compared] as $stale |
      [$ours[] | select(.synced != $commit) | .synced] as $elsewhere |
      if $sync != "Synced" or $health != "Healthy" then "\($sync), \($health)"
      elif ($stale | length) > 0 then "compared with \($stale[0])"
      elif ($elsewhere | length) == 0 then empty
      elif $elsewhere[0] == "" then "synced at no revision"
      else "synced at \($elsewhere[0][:7])"
      end;
    [input.items[] | select($group == "" or .metadata.labels["k3d-lab/group"] == $group)] as $listed |
    ($listed | map({key: .metadata.name, value: .}) | from_entries) as $by_name |
    if ($ARGS.positional | length) == 0 then $listed[] | "\(.metadata.name): \(why)"
    else
      $ARGS.positional[] as $name | $by_name[$name] |
      if $gone then select(. != null) | "\($name): still there"
      elif . == null then "\($name): not generated yet"
      else "\($name): \(why)"
      end
    end' --args "$@"
}

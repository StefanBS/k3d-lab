# Pausing one Application with 'just pause', resuming it, and which are paused. Sourced by
# lib.sh, and on its own by scripts/tests/, so it sets no shell options and runs nothing
# when sourced.
# shellcheck shell=bash
# shellcheck disable=SC2016 # the $names in the jq programs are jq's, not the shell's.

# A pause is a deny sync window on the Application's project, for that Application
# alone: ArgoCD then neither syncs nor self-heals it, so changes made by hand stay. Its
# description tells it apart from any other window.
PAUSE_DESCRIPTION="just pause"

# paused_applications: prints each paused Application's name, one per line. Fails when
# the Lab's AppProjects can't be read.
paused_applications() {
  local projects
  projects=$(kc -n argocd get appprojects -o json) || return 1
  jq -r --arg d "$PAUSE_DESCRIPTION" '.items[].spec.syncWindows // [] | .[] | select(.description == $d) | .applications[]' <<<"$projects"
}

# pause_application <name>: adds the Application's pause to its project, unless it's
# there already.
pause_application() { _pause_patch "$1" pause_windows; }

# resume_application <name>: removes the Application's pause from its project, and has
# ArgoCD compare it with Git now, rather than at its next poll. wait_settled then waits
# for ArgoCD to put Git back.
resume_application() {
  _pause_patch "$1" resume_windows
  refresh_applications "$1"
}

# _pause_patch <application> pause_windows|resume_windows: sets its project's sync windows
# to what the function makes of them. The resourceVersion makes the patch fail, rather
# than drop a window, if the project changed since it was read.
_pause_patch() {
  local application=$1 windows=$2 project project_json
  project=$(kc -n argocd get application "$application" -o jsonpath='{.spec.project}' 2>/dev/null) ||
    die "the Lab has no Application named '$application'; 'kubectl -n argocd get applications' lists them"
  project_json=$(kc -n argocd get appproject "$project" -o json) || die "can't read the AppProject $project"
  jq -n --argjson windows "$("$windows" "$application" <<<"$project_json")" \
    --arg version "$(jq -r .metadata.resourceVersion <<<"$project_json")" \
    '{"metadata": {"resourceVersion": $version}, "spec": {"syncWindows": $windows}}' |
    kc -n argocd patch appproject "$project" --type merge --patch-file /dev/stdin >/dev/null
}

# pause_windows <application>: reads its AppProject (kubectl get appproject -o json) on
# stdin, and prints the project's sync windows with the Application's pause among them.
# A window opens at each match of its schedule and stays open for its duration, so one
# that opens every minute, for an hour, never closes.
pause_windows() {
  _pause_jq "$1" '
    if any($windows[]; is_pause) then $windows
    else $windows + [{"kind": "deny", "schedule": "* * * * *", "duration": "1h", "applications": [$app],
      "manualSync": false, "description": $d}]
    end'
}

# resume_windows <application>: like pause_windows, without the Application's pause.
resume_windows() { _pause_jq "$1" '$windows | map(select(is_pause | not))'; }

# _pause_jq <application> <program>: runs the program with the project's sync windows in
# $windows, and is_pause true for the Application's pause. It matches on the fields it
# sets, not the whole window, in case ArgoCD adds others.
_pause_jq() {
  jq --arg app "$1" --arg d "$PAUSE_DESCRIPTION" '
    def is_pause: .description == $d and .applications == [$app];
    (.spec.syncWindows // []) as $windows | '"$2"
}

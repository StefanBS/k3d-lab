# Which Applications 'just pause' has paused. Sourced by pause.sh and verify.sh, and on
# its own by scripts/tests/, so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash
# shellcheck disable=SC2016 # the $names in the jq programs are jq's, not the shell's.

# A pause is a deny sync window on the Application's project, for that Application
# alone: ArgoCD then neither syncs nor self-heals it, so changes made by hand stay. Its
# description tells it apart from any other window.
PAUSE_DESCRIPTION="just pause"

# paused_applications: reads the Lab's AppProjects (kubectl get appprojects -o json) on
# stdin, and prints each paused Application's name, one per line.
paused_applications() {
  jq -r --arg d "$PAUSE_DESCRIPTION" '.items[].spec.syncWindows // [] | .[] | select(.description == $d) | .applications[]'
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

#!/usr/bin/env bash
# Points the running Lab at another pushed branch or tag, as `just up` would have built
# it, without rebuilding it, and stops once every Application has synced it.
# Usage: track.sh [<branch or tag>] [--debug]. By default, the branch checked out here,
# since verify runs the checks from this checkout (see up.sh).
# --debug makes it a debugging run, which also records the pressure and ends with verify
# (run-diagnostics.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/run-diagnostics.sh
source "$(dirname "$0")/lib/run-diagnostics.sh"

usage="usage: just track [<branch or tag>] [--debug]"
revision=''
debug=''
for arg; do
  case $arg in
    --debug) debug=1 ;;
    -*) die "unknown argument '$arg'; $usage" ;;
    *)
      [[ -z $revision ]] || die "$usage"
      revision=$arg
      ;;
  esac
done
[[ -n $revision ]] || revision=$(git -C "$LAB_ROOT" branch --show-current)
[[ -n $revision ]] || die "no branch is checked out; check one out, or pass <branch or tag>"

# A sync can be heavy enough for k3s to stall on its datastore, and the Pressure then says
# why (run-diagnostics.sh).
[[ -z $debug ]] || record_pressure

need_root_application
commit=$(pushed_commit "$revision")
# A paused Application never syncs the new commit, so the wait below would only time out.
paused=$(paused_applications | paste -sd' ') || die "can't read the Lab's AppProjects"
[[ -z $paused ]] || die "paused, so they'd never sync $revision: $paused; 'just resume <name>' each first"
start_run_clock
trap 'report_run track "$debug"' EXIT

log "Pointing the Lab at $revision (${commit:0:7})"
root_application_track "$revision"

log "Waiting for the root Application to sync $revision"
wait_settled 900 --at "$commit" root
# The ApplicationSets read the branch's components again, as up.sh waits for them to:
# when only its commit changed, their own spec didn't, so they'd wait for their next
# poll to generate a new component's Application.
log "Waiting for the ApplicationSets to generate the Applications"
refresh_applicationsets 300
wait_applicationsets 300
# Likewise, an Application whose spec the root's sync didn't change waits for a refresh.
refresh_applications
log "Waiting for every Application to sync $revision"
wait_settled 900 --at "$commit"

[[ -z $debug ]] || exec "$LAB_ROOT/scripts/verify.sh"

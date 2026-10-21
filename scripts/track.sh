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
need_none_paused
start_run_clock
trap 'report_run track "$debug"' EXIT

log "Pointing the Lab at $revision (${commit:0:7})"
root_application_track "$revision"

settle_track "$commit"

[[ -z $debug ]] || exec "$LAB_ROOT/scripts/verify.sh"

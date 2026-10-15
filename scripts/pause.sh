#!/usr/bin/env bash
# Pauses one Application, so changes made by hand to it stay for an experiment that has
# no business in Git, and resumes it, so ArgoCD puts Git back. The pause is a deny sync
# window on its project (lib/pauses.sh), which the root Application leaves alone.
# Usage: pause.sh pause|resume <Application>
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

(($# == 2)) && [[ $1 == pause || $1 == resume ]] || die "usage: just pause|resume <Workload or Platform component>"
action=$1 application=$2

need_lab
"${action}_application" "$application"

if [[ $action == pause ]]; then
  log "Paused $application: ArgoCD leaves it as it is until 'just resume $application'"
  exit
fi

log "Waiting for ArgoCD to put $application back as Git has it"
wait_settled 600 "$application"
log "Resumed $application"

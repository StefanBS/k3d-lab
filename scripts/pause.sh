#!/usr/bin/env bash
# Pauses one Application, so changes made by hand to it stay for an experiment that has
# no business in Git, and resumes it, so ArgoCD puts Git back. The pause is a deny sync
# window on its project (pause-state.sh), which the root Application leaves alone.
# Usage: pause.sh pause|resume <Application>
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=pause-state.sh
source "$(dirname "$0")/pause-state.sh"

(($# == 2)) && [[ $1 == pause || $1 == resume ]] || die "usage: just pause|resume <Workload or Platform component>"
action=$1 application=$2

lab_exists || die "there's no Lab; run 'just up'"
project=$(kc -n argocd get application "$application" -o jsonpath='{.spec.project}' 2>/dev/null) ||
  die "the Lab has no Application named '$application'; 'kubectl -n argocd get applications' lists them"

# The resourceVersion makes the patch fail, rather than drop a window, if the project
# changed since it was read.
project_json=$(kc -n argocd get appproject "$project" -o json)
jq -n --argjson windows "$("${action}_windows" "$application" <<<"$project_json")" \
  --arg version "$(jq -r .metadata.resourceVersion <<<"$project_json")" \
  '{"metadata": {"resourceVersion": $version}, "spec": {"syncWindows": $windows}}' |
  kc -n argocd patch appproject "$project" --type merge --patch-file /dev/stdin >/dev/null

if [[ $action == pause ]]; then
  log "Paused $application: ArgoCD leaves it as it is until 'just resume $application'"
  exit
fi

# Without a refresh, ArgoCD would compare the Application again only at its next poll.
kc -n argocd annotate application "$application" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
log "Waiting for ArgoCD to put $application back as Git has it"
last='' deadline=$((SECONDS + 600))
while :; do
  # A sync can be heavy enough for k3s to restart, so a failed get is waited out too.
  state=$(kc -n argocd get application "$application" \
    -o jsonpath='{.status.sync.status}, {.status.health.status}' 2>/dev/null) ||
    state="the Lab's API isn't answering"
  [[ $state != "Synced, Healthy" ]] || break
  if [[ $state != "$last" ]]; then
    log "Still waiting: $state"
    last=$state
  fi
  ((SECONDS < deadline)) || die "$application isn't Synced and Healthy after 10 minutes: $state"
  sleep 5
done
log "Resumed $application"

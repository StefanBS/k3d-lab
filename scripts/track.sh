#!/usr/bin/env bash
# Points the running Lab at another pushed branch or tag, as `just up` would have built
# it, without rebuilding it; then runs verify.
# Usage: track.sh [<branch or tag>]. By default, the branch checked out here, since
# verify runs the checks from this checkout (see up.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=track-state.sh
source "$(dirname "$0")/track-state.sh"
# shellcheck source=pause-state.sh
source "$(dirname "$0")/pause-state.sh"

(($# <= 1)) || die "usage: just track [<branch or tag>]"
revision=${1:-$(git -C "$LAB_ROOT" branch --show-current)}
[[ -n $revision ]] || die "no branch is checked out; check one out, or pass <branch or tag>"

lab_exists || die "there's no Lab; run 'just up'"
kc -n argocd get application/root >/dev/null 2>&1 || die "the Lab has no root Application; run 'just down', then 'just up'"
commit=$(pushed_commit "$revision")
# A paused Application never syncs the new commit, so the wait below would only time out.
paused=$(kc -n argocd get appprojects -o json | paused_applications | paste -sd' ')
[[ -z $paused ]] || die "paused, so they'd never sync $revision: $paused; 'just resume <name>' each first"

# The same two fields up.sh sets: the root Application's own revision, and the one its
# chart gives every Application it generates. A hard refresh makes ArgoCD read the
# branch again now, rather than at its next poll, also when only its commit changed.
log "Pointing the Lab at $revision (${commit:0:7})"
REVISION=$revision yq -n -o json '
  .metadata.annotations."argocd.argoproj.io/refresh" = "hard" |
  .spec.source.targetRevision = strenv(REVISION) |
  .spec.source.helm.valuesObject.revision = strenv(REVISION)' |
  kc -n argocd patch application/root --type merge --patch-file /dev/stdin >/dev/null

# Waits until applications_behind prints nothing for the Applications that `kc get` selects,
# logging what's still behind whenever that changes. Gives up after 15 minutes.
wait_caught_up() {
  local behind last='' deadline=$((SECONDS + 900))
  while :; do
    # A sync can be heavy enough for k3s to restart, so a failed get is waited out too.
    behind=$(kc -n argocd get applications "$@" -o json 2>/dev/null |
      applications_behind "$LAB_REPO" "$commit") || behind="the Lab's API isn't answering"
    [[ -n $behind ]] || return 0
    if [[ $behind != "$last" ]]; then
      log "Still behind: $(cut -d: -f1 <<<"$behind" | paste -sd' ')"
      last=$behind
    fi
    ((SECONDS < deadline)) || die "ArgoCD hasn't caught up with $revision after 15 minutes:"$'\n'"$behind"
    sleep 5
  done
}

# True once the ApplicationSet controller has taken every refresh asked of it: it removes
# the annotation when it has.
applicationsets_refreshed() {
  local pending
  pending=$(kc -n argocd get applicationsets \
    -o jsonpath='{.items[*].metadata.annotations.argocd\.argoproj\.io/application-set-refresh}' 2>/dev/null) &&
    [[ -z $pending ]]
}

log "Waiting for the root Application to sync $revision"
wait_caught_up --field-selector metadata.name=root
# The ApplicationSets read the branch's components again, as up.sh waits for them to:
# when only its commit changed, their own spec didn't, so they'd wait for their next
# poll to generate a new component's Application.
log "Waiting for the ApplicationSets to generate the Applications"
kc -n argocd annotate applicationsets --all argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
retry 300 applicationsets_refreshed || die "the ApplicationSets haven't refreshed after 5 minutes"
kc -n argocd wait applicationsets --all --for=condition=ResourcesUpToDate --timeout=5m >/dev/null
# Likewise, an Application whose spec the root's sync didn't change waits for a refresh.
kc -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null
log "Waiting for every Application to sync $revision"
wait_caught_up

exec "$LAB_ROOT/scripts/verify.sh"

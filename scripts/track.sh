#!/usr/bin/env bash
# Points the running Lab at another pushed branch or tag, as `just up` would have built
# it, without rebuilding it; then runs verify.
# Usage: track.sh [<branch or tag>]. By default, the branch checked out here, since
# verify runs the checks from this checkout (see up.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=track-state.sh
source "$(dirname "$0")/track-state.sh"

(($# <= 1)) || die "usage: just track [<branch or tag>]"
revision=${1:-$(git -C "$LAB_ROOT" branch --show-current)}
[[ -n $revision ]] || die "no branch is checked out; check one out, or pass <branch or tag>"

lab_exists || die "there's no Lab; run 'just up'"
kc -n argocd get application/root >/dev/null 2>&1 || die "the Lab has no root Application; run 'just down', then 'just up'"
commit=$(pushed_commit "$revision")

# The same two fields up.sh sets: the root Application's own revision, and the one its
# chart gives every Application it generates. A hard refresh makes ArgoCD read the
# branch again now, rather than at its next poll, also when only its commit changed.
log "Pointing the Lab at $revision (${commit:0:7})"
REVISION=$revision yq -n -o json '
  .metadata.annotations."argocd.argoproj.io/refresh" = "hard" |
  .spec.source.targetRevision = strenv(REVISION) |
  .spec.source.helm.valuesObject.revision = strenv(REVISION)' |
  kc -n argocd patch application/root --type merge --patch-file /dev/stdin >/dev/null

# Waits until apps_behind prints nothing for the Applications that `kc get` selects,
# logging what's still behind whenever that changes. Gives up after 15 minutes.
wait_caught_up() {
  local behind last='' deadline=$((SECONDS + 900))
  while :; do
    behind=$(kc -n argocd get applications "$@" -o json | apps_behind "$LAB_REPO" "$commit")
    [[ -n $behind ]] || return 0
    if [[ $behind != "$last" ]]; then
      log "Still behind: $(cut -d: -f1 <<<"$behind" | paste -sd' ')"
      last=$behind
    fi
    ((SECONDS < deadline)) || die "ArgoCD hasn't caught up with $revision after 15 minutes:"$'\n'"$behind"
    sleep 5
  done
}

log "Waiting for the root Application to sync $revision"
wait_caught_up --field-selector metadata.name=root
# Every Application whose spec the root's sync changed is compared again on its own; one
# whose spec it didn't, when only the branch's commit changed, waits for a refresh.
kc -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null
log "Waiting for every Application to sync $revision"
wait_caught_up

exec "$LAB_ROOT/scripts/verify.sh"

#!/usr/bin/env bash
# Points the running Lab at another pushed branch or tag, as `just up` would have built
# it, without rebuilding it, and stops once every Application has synced it.
# Usage: track.sh [<branch or tag>] [--demos|--no-demos] [--debug]. By default, the branch
# checked out here, since verify runs the checks from this checkout (see up.sh).
# --demos adds the Demos to the Lab, and --no-demos removes them. Without either, the Lab
# keeps what it has.
# --debug makes it a debugging run, which also records the pressure and ends with verify
# (run-diagnostics.sh). It debugs the Lab as it is, so unlike up's, it adds no Demos.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=track-state.sh
source "$(dirname "$0")/track-state.sh"
# shellcheck source=demos-state.sh
source "$(dirname "$0")/demos-state.sh"
# shellcheck source=pause-state.sh
source "$(dirname "$0")/pause-state.sh"
# shellcheck source=run-diagnostics.sh
source "$(dirname "$0")/run-diagnostics.sh"

usage="usage: just track [<branch or tag>] [--demos|--no-demos] [--debug]"
revision=''
# Whether the Lab is to have its Demos: true, false, or empty to keep what it has.
demos=''
for arg; do
  case $arg in
    --debug) RUN_DEBUG=1 ;;
    --demos)
      [[ $demos != false ]] || die "$usage"
      demos=true
      ;;
    --no-demos)
      [[ $demos != true ]] || die "$usage"
      demos=false
      ;;
    -*) die "unknown argument '$arg'; $usage" ;;
    *)
      [[ -z $revision ]] || die "$usage"
      revision=$arg
      ;;
  esac
done
[[ -n $revision ]] || revision=$(git -C "$LAB_ROOT" branch --show-current)
[[ -n $revision ]] || die "no branch is checked out; check one out, or pass <branch or tag>"

# A sync can be heavy enough for k3s to stall on its datastore, and the pressure then says
# why (verify.sh).
[[ -z $RUN_DEBUG ]] || record_pressure

lab_exists || die "there's no Lab; run 'just up'"
kc -n argocd get application/root >/dev/null 2>&1 || die "the Lab has no root Application; run 'just down', then 'just up'"
commit=$(pushed_commit "$revision")
# A paused Application never syncs the new commit, so the wait below would only time out.
paused=$(kc -n argocd get appprojects -o json | paused_applications | paste -sd' ')
[[ -z $paused ]] || die "paused, so they'd never sync $revision: $paused; 'just resume <name>' each first"
export LAB_RUN_SINCE
LAB_RUN_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
trap 'report_run track' EXIT

# The same fields up.sh sets: the root Application's own revision, and the one its
# chart gives every Application it generates. A hard refresh makes ArgoCD read the
# branch again now, rather than at its next poll, also when only its commit changed.
# `demos` is set only when told, so the Lab otherwise keeps the Demos it has, or none.
log "Pointing the Lab at $revision (${commit:0:7})"
patch='
  .metadata.annotations."argocd.argoproj.io/refresh" = "hard" |
  .spec.source.targetRevision = strenv(REVISION) |
  .spec.source.helm.valuesObject.revision = strenv(REVISION)'
[[ -z $demos ]] || patch+=" | .spec.source.helm.valuesObject.demos = $demos"
REVISION=$revision yq -n -o json "$patch" |
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

# wait_demos <present|gone> <name>...: waits until each of those Applications is, logging
# which aren't yet whenever that changes. Gives up after 5 minutes.
wait_demos() {
  local pending last='' deadline=$((SECONDS + 300))
  while :; do
    # As in wait_caught_up, a failed get is waited out.
    pending=$(kc -n argocd get applications -o json 2>/dev/null | demos_pending "$@" 2>/dev/null) ||
      pending="the Lab's API isn't answering"
    [[ -n $pending ]] || return 0
    if [[ $pending != "$last" ]]; then
      log "Not yet $1: $(paste -sd' ' <<<"$pending")"
      last=$pending
    fi
    ((SECONDS < deadline)) || die "the Demos' Applications aren't $1 after 5 minutes:"$'\n'"$pending"
    sleep 5
  done
}

# namespace_deleted <name>: asks for the namespace to be deleted, and succeeds once it's
# gone. A failed request is "not yet", for retry.
namespace_deleted() {
  local left
  kc delete namespace "$1" --ignore-not-found --wait=false >/dev/null 2>&1 &&
    left=$(kc get namespace "$1" --ignore-not-found -o name 2>/dev/null) && [[ -z $left ]]
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
# The Demos, as this checkout has them, like the checks that verify runs.
mapfile -t demo_components < <(demo_dirs)
# When only `demos` changed, the root Application still said Synced at this commit until
# ArgoCD compared it again, so the waits above may have passed before the workloads
# ApplicationSet changed. The Demos' Applications say when it has.
if [[ -n $demos ]] && ((${#demo_components[@]})); then
  if [[ $demos == true ]]; then
    log "Waiting for the Demos' Applications"
    wait_demos present "${demo_components[@]##*/}"
  else
    log "Waiting for the Demos' Applications to go"
    wait_demos gone "${demo_components[@]##*/}"
  fi
fi
# Likewise, an Application whose spec the root's sync didn't change waits for a refresh.
kc -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null
log "Waiting for every Application to sync $revision"
wait_caught_up

# ArgoCD deletes what a Demo's Application installed, but not the namespace it created
# for it, which still carries the Workloads' label: network-policy-enforced would fail on
# a Workload namespace that no Application has.
if [[ $demos == false ]]; then
  for dir in "${demo_components[@]}"; do
    namespace=$(component_namespace "$dir")
    log "Deleting the namespace $namespace"
    retry 300 namespace_deleted "$namespace" || die "the namespace $namespace is still there after 5 minutes"
  done
fi

[[ -z $RUN_DEBUG ]] || exec "$LAB_ROOT/scripts/verify.sh"

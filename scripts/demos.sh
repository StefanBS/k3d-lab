#!/usr/bin/env bash
# Adds the Demos to the running Lab, or removes them, without rebuilding it, and stops
# once their Applications are Synced and Healthy, or gone with their namespaces.
# Usage: demos.sh on|off. `just up --demos` builds a Lab with them from the start.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=demos-state.sh
source "$(dirname "$0")/demos-state.sh"

(($# == 1)) && [[ $1 == on || $1 == off ]] || die "usage: just demos on|off"
if [[ $1 == on ]]; then demos=true want=ready; else demos=false want=gone; fi

lab_exists || die "there's no Lab; run 'just up'"
kc -n argocd get application/root >/dev/null 2>&1 || die "the Lab has no root Application; run 'just down', then 'just up'"
# The Demos, as this checkout has them, like the checks that verify runs.
mapfile -t demo_components < <(demo_dirs)
((${#demo_components[@]})) || die "no Workload in workloads/ is a Demo (role: demo in its component.yaml)"

# The value up.sh sets: the workloads ApplicationSet leaves the Demos out while it's
# false. A hard refresh makes ArgoCD render the root Application again now, rather than
# at its next poll.
log "Turning the Lab's Demos $1: ${demo_components[*]##*/}"
yq -n -o json ".metadata.annotations.\"argocd.argoproj.io/refresh\" = \"hard\" |
  .spec.source.helm.valuesObject.demos = $demos" |
  kc -n argocd patch application/root --type merge --patch-file /dev/stdin >/dev/null

# Run again on a Lab that already has them, or doesn't, it finds nothing to wait for.
last='' deadline=$((SECONDS + 600))
while :; do
  # A sync can be heavy enough for k3s to restart, so a failed get is waited out too.
  pending=$(kc -n argocd get applications -o json 2>/dev/null | demos_pending "$want" "${demo_components[@]##*/}" 2>/dev/null) ||
    pending="the Lab's API isn't answering"
  [[ -n $pending ]] || break
  if [[ $pending != "$last" ]]; then
    log "Still waiting: $(paste -sd';' <<<"$pending")"
    last=$pending
  fi
  ((SECONDS < deadline)) || die "the Demos' Applications aren't $want after 10 minutes:"$'\n'"$pending"
  sleep 5
done
[[ $1 == off ]] || exit 0

# namespace_deleted <name>: asks for the namespace to be deleted, and succeeds once it's
# gone. A failed request is "not yet", for retry.
namespace_deleted() {
  local left
  kc delete namespace "$1" --ignore-not-found --wait=false >/dev/null 2>&1 &&
    left=$(kc get namespace "$1" --ignore-not-found -o name 2>/dev/null) && [[ -z $left ]]
}

# ArgoCD deletes what a Demo's Application installed, but not the namespace it created
# for it, which still carries the Workloads' label: network-policy-enforced would fail on
# a Workload namespace that no Application has.
for dir in "${demo_components[@]}"; do
  namespace=$(component_namespace "$dir")
  log "Deleting the namespace $namespace"
  retry 300 namespace_deleted "$namespace" || die "the namespace $namespace is still there after 5 minutes"
done

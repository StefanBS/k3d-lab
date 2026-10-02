#!/usr/bin/env bash
# Checks that every ArgoCD Application is Synced and Healthy, with one exception: an
# Application that is Synced, and unhealthy only because DaemonSets' pods are missing
# from a Joined GPU Node that is NotReady, i.e. powered off (ADR 0002). Cilium's agent
# tolerates every taint, so its DaemonSet still counts that node.
# ArgoCD keeps each resource's health in the Application for this
# (controller.resource.health.persist, platform/argocd/values.yaml).
# Called by the check's script step, whose kubectl already points at the Lab.
set -euo pipefail

apps=$(kubectl -n argocd get applications -o json)
off_nodes=$("$(dirname "$0")/ready-nodes.sh" --not-ready -l k3d-lab/gpu)

# Whether a DaemonSet is short only of pods on the GPU Node while it's off.
daemonset_short_only_on_off_nodes() {
  local namespace=$1 name=$2 ds selector desired available updated on_off
  ds=$(kubectl -n "$namespace" get daemonset "$name" -o json) || return 1
  read -r desired available updated < <(yq -p json -oy \
    '[.status.desiredNumberScheduled, .status.numberAvailable // 0, .status.updatedNumberScheduled // .status.desiredNumberScheduled] | join(" ")' <<<"$ds")
  selector=$(yq -p json -oy '.spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")' <<<"$ds")
  on_off=$(kubectl -n "$namespace" get pods -l "$selector" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
    grep -cxF -f <(echo "$off_nodes")) || true
  ((desired - available <= on_off && desired - updated <= on_off))
}

# Whether every unhealthy resource of the Application is such a DaemonSet.
excused() {
  local kind namespace name found=false
  while read -r kind namespace name; do
    [[ $kind == DaemonSet ]] && daemonset_short_only_on_off_nodes "$namespace" "$name" || return 1
    found=true
  done < <(APP=$1 yq -p json -oy '.items[] | select(.metadata.name == strenv(APP)) | .status.resources[]
    | select(.health.status != null and .health.status != "Healthy")
    | .kind + " " + (.namespace // "-") + " " + .name' <<<"$apps")
  [[ $found == true ]]
}

bad=0
while read -r app sync health; do
  [[ $sync == Synced && $health == Healthy ]] && continue
  if [[ $sync == Synced && -n $off_nodes ]] && excused "$app"; then
    echo "WARN  $app is $health only because the GPU Node is off"
    continue
  fi
  echo "FAIL  $app is ${sync:-not synced} and ${health:-of unknown health}"
  bad=1
done < <(yq -p json -oy '.items[] | .metadata.name + " " + .status.sync.status + " " + .status.health.status' <<<"$apps")
exit "$bad"

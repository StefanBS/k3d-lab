# The Lab's DaemonSets: waiting for their pods to run on every node. Sourced by lib.sh, and
# on its own by scripts/tests/, so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# daemonsets_unready <Application>...: reads the Lab's DaemonSets (kubectl get daemonsets
# -A -o json) on stdin, and prints a line for each DaemonSet of those Applications that
# hasn't a Ready, up-to-date pod on each node it should run on, as "<namespace>/<name>:
# <why>". One the controller hasn't counted yet has no status. Fails when there's nothing
# to read, as when the request failed.
daemonsets_unready() {
  jq -rn '
    input.items[] |
    # ArgoCD tracking id starts with the DaemonSet Application: <app>:apps/DaemonSet:...
    select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "" | split(":")[0]) | IN($ARGS.positional[])) |
    .status as $s | "\(.metadata.namespace)/\(.metadata.name): " +
    if $s.desiredNumberScheduled == null then "not counted yet"
    elif $s.numberReady != $s.desiredNumberScheduled or $s.updatedNumberScheduled != $s.desiredNumberScheduled then
      "\($s.numberReady // 0) of \($s.desiredNumberScheduled) Ready, \($s.updatedNumberScheduled // 0) up to date"
    else empty
    end' --args "$@"
}

# wait_daemonsets_ready <seconds> <Application>...: waits until every DaemonSet of those
# Applications has a Ready, up-to-date pod on each node it should run on. Gives up after
# that many seconds.
wait_daemonsets_ready() {
  local seconds=$1
  shift
  wait_until_none "$seconds" "these DaemonSets aren't Ready on every node" daemonsets_in_lab_unready "$@"
}
daemonsets_in_lab_unready() { kc get daemonsets -A -o json | daemonsets_unready "$@"; }

#!/usr/bin/env bash
# Usage: on-ready-nodes.sh <namespace> <pod selector> <kubectl exec args>...
# Runs a command in the pod matching the selector on every Ready node, the GPU Node
# included when it's Joined, and fails if it fails on any of them.
# Chainsaw has no step that runs once per node (ADR 0004), so its script steps call
# this. They point kubectl at the Lab, through a context named chainsaw.
set -euo pipefail

namespace=$1 selector=$2
shift 2

# Waits for the pod on the given node to be Ready, and prints its name. Otherwise, says
# why on stderr and fails. Each node gets 30s to show its pod and 30s for it to be Ready,
# which keeps a few nodes within the exec timeout (.chainsaw.yaml), so a slow node is named.
pod_on_node() {
  local node=$1 pod="" attempt
  for attempt in {1..15}; do
    # Skips pods being deleted: while a pod is replaced, the node briefly has two.
    pod=$(kubectl -n "$namespace" get pods -l "$selector" --field-selector "spec.nodeName=$node" \
      -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}' |
      awk 'NF == 1 { print "pod/" $1; exit }')
    [[ -n $pod ]] && break
    ((attempt < 15)) && sleep 2
  done
  [[ -n $pod ]] || {
    echo "FAIL  $node: no pod matching $selector" >&2
    return 1
  }
  kubectl -n "$namespace" wait --for=condition=Ready "$pod" --timeout=30s >/dev/null 2>&1 || {
    echo "FAIL  $node: $pod is not Ready" >&2
    return 1
  }
  echo "$pod"
}

nodes=$("$(dirname "$0")/ready-nodes.sh")
[[ -n $nodes ]] || {
  echo "FAIL  no Ready nodes"
  exit 1
}

bad=0
for node in $nodes; do
  pod=$(pod_on_node "$node") || {
    bad=1
    continue
  }
  if out=$(kubectl -n "$namespace" exec "$pod" "$@" 2>&1); then
    echo "OK    $node"
  else
    # The command's own last line, rather than kubectl's "command terminated" after it.
    echo "FAIL  $node: $(grep -v -e '^command terminated with exit code' -e '^$' <<<"$out" | tail -n1)"
    bad=1
  fi
done
exit "$bad"

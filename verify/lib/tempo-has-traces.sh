#!/usr/bin/env bash
# Usage: tempo-has-traces.sh <namespace>
# Checks that Tempo holds, for every Ready node, the GPU Node included when it's Joined,
# the trace the probe client in the namespace sent there (send-trace.sh), tagged by
# Alloy with that client's namespace and pod, which Grafana links to its logs with.
# Tempo can return a trace within seconds, but it retries for 2m.
# Run by traces-reach-tempo, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail

namespace=$1

# Usage: pod_tags <trace ID>
# Prints "<namespace> <pod>" for each service in the trace, as Alloy tagged it. Queries
# through the API server's proxy to Tempo's Service, whose HTTP API port the chart
# names tempo-prom-metrics.
pod_tags() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/tempo:tempo-prom-metrics/proxy/api/v2/traces/$1" |
    yq -p json '.trace.resourceSpans[].resource.attributes |
      (.[] | select(.key == "k8s.namespace.name") | .value.stringValue) + " " +
      (.[] | select(.key == "k8s.pod.name") | .value.stringValue)'
}

nodes=$("$(dirname "$0")/ready-nodes.sh")
[[ -n $nodes ]] || {
  echo "FAIL  no Ready nodes"
  exit 1
}

for attempt in {1..24}; do
  missing=()
  for node in $nodes; do
    # The ID send-trace.sh gave that node's trace.
    trace=$(printf '%s/%s' "$namespace" "$node" | md5sum | cut -c1-32)
    pod=$(kubectl -n "$namespace" get pods -l app=client --field-selector "spec.nodeName=$node" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || pod=""
    found=$(pod_tags "$trace" 2>&1) || found=""
    # Both services' spans came from that pod.
    [[ $(grep -cxF "$namespace $pod" <<<"$found") == 2 ]] || missing+=("$node")
  done
  ((${#missing[@]})) || break
  ((attempt < 24)) && sleep 5
done

for node in $nodes; do
  [[ " ${missing[*]} " == *" $node "* ]] || echo "OK    $node"
done
((${#missing[@]} == 0)) || {
  printf 'FAIL  no trace from %s, tagged with its client pod\n' "${missing[@]}"
  exit 1
}

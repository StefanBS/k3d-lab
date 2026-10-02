#!/usr/bin/env bash
# Usage: tempo-has-traces.sh <namespace>
# Checks that Tempo holds, for every Ready node, the GPU Node included when it's Joined,
# the trace the probe client in the namespace sent there (send-trace.sh), tagged by
# Alloy with that client's namespace and pod, which Grafana links to its logs with.
# Tempo can return a trace within seconds, but it retries for 2m.
# Run by traces-reach-tempo, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

namespace=$1

# Usage: pod_tags <trace ID>
# Prints "<namespace> <pod>" for each service in the trace, as Alloy tagged it. Tempo's
# chart names its HTTP API port tempo-prom-metrics.
pod_tags() {
  monitoring_get tempo:tempo-prom-metrics "api/v2/traces/$1" |
    yq -p json '.trace.resourceSpans[].resource.attributes |
      (.[] | select(.key == "k8s.namespace.name") | .value.stringValue) + " " +
      (.[] | select(.key == "k8s.pod.name") | .value.stringValue)'
}

# Prints each node whose trace Tempo doesn't hold yet, tagged with its client pod.
missing_traces() {
  local node trace pod found
  for node in "${nodes[@]}"; do
    # The ID send-trace.sh gave that node's trace.
    trace=$(printf '%s/%s' "$namespace" "$node" | md5sum | cut -c1-32)
    pod=$(node_pod "$namespace" app=client "$node" 2>/dev/null) || pod=""
    found=$(pod_tags "$trace" 2>&1) || found=""
    # Both services' spans came from that pod.
    [[ -n $pod && $(grep -cxF "$namespace $pod" <<<"$found") == 2 ]] || echo "$node"
  done
}

require_ready_nodes
retry missing_traces
report 'no trace from %s, tagged with its client pod' "${nodes[@]}"

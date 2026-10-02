#!/usr/bin/env bash
# Usage: prometheus-has-trace-metrics.sh <namespace>
# Checks that Prometheus holds the metrics Tempo's metrics generator made from the traces
# the probe clients in the namespace sent (send-trace.sh): the service graph's edge from
# <namespace>-client to <namespace>-web, and the span metrics of <namespace>-client.
# Tempo writes them every 15s: it retries for 2m.
# Run by traces-reach-tempo, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

namespace=$1

# Each named after what it finds, then the query, which uses the service names
# send-trace.sh gives the trace.
targets=(
  "service graph: traces_service_graph_request_total{client=\"$namespace-client\", server=\"$namespace-web\"}"
  "span metrics: traces_spanmetrics_calls_total{service=\"$namespace-client\"}"
)

# Prints each target whose query finds no series yet.
missing_series() {
  local target count
  for target in "${targets[@]}"; do
    count=$(prometheus_query "${target#*: }" '.data.result | length' 2>&1) || count=0
    [[ $count =~ ^[1-9] ]] || echo "$target"
  done
}

retry missing_series
report 'no %s' "${targets[@]}"

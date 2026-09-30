#!/usr/bin/env bash
# Usage: prometheus-has-trace-metrics.sh <namespace>
# Checks that Prometheus holds the metrics Tempo's metrics generator made from the traces
# the probe clients in the namespace sent (send-trace.sh): the service graph's edge from
# <namespace>-client to <namespace>-web, and the span metrics of <namespace>-client.
# Tempo writes them every 15s: it retries for 2m.
# Run by traces-reach-tempo, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail

namespace=$1

# Usage: series <PromQL>
# Prints how many series the query returns, through the API server's proxy to
# Prometheus' Service.
series() {
  local encoded
  encoded=$(Q=$1 yq -n 'strenv(Q) | @uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:http/proxy/api/v1/query?query=$encoded" |
    yq -p json '.data.result | length'
}

declare -A queries=(
  ["service graph"]="traces_service_graph_request_total{client=\"$namespace-client\", server=\"$namespace-web\"}"
  ["span metrics"]="traces_spanmetrics_calls_total{service=\"$namespace-client\"}"
)

for attempt in {1..24}; do
  missing=()
  for name in "${!queries[@]}"; do
    count=$(series "${queries[$name]}" 2>&1) || count=0
    [[ $count =~ ^[1-9] ]] || missing+=("$name")
  done
  ((${#missing[@]})) || break
  ((attempt < 24)) && sleep 5
done

for name in "${!queries[@]}"; do
  [[ " ${missing[*]} " == *" $name "* ]] || echo "OK    $name: ${queries[$name]}"
done
((${#missing[@]} == 0)) || {
  for name in "${missing[@]}"; do
    echo "FAIL  no $name: ${queries[$name]}"
  done
  exit 1
}

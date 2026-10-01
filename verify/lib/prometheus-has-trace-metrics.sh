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

# Usage: series_count <PromQL>
# Prints how many series the query returns, through the API server's proxy to
# Prometheus' Service.
series_count() {
  local encoded
  encoded=$(Q=$1 yq -n 'strenv(Q) | @uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:http/proxy/api/v1/query?query=$encoded" |
    yq -p json '.data.result | length'
}

# The service names send-trace.sh gives the trace. Each query's name is at the same
# index as the query.
names=("service graph" "span metrics")
queries=(
  "traces_service_graph_request_total{client=\"$namespace-client\", server=\"$namespace-web\"}"
  "traces_spanmetrics_calls_total{service=\"$namespace-client\"}"
)

for attempt in {1..24}; do
  missing=()
  for i in "${!queries[@]}"; do
    count=$(series_count "${queries[i]}" 2>&1) || count=0
    [[ $count =~ ^[1-9] ]] || missing+=("$i")
  done
  ((${#missing[@]})) || break
  ((attempt < 24)) && sleep 5
done

for i in "${!queries[@]}"; do
  [[ " ${missing[*]} " == *" $i "* ]] || echo "OK    ${names[i]}: ${queries[i]}"
done
((${#missing[@]} == 0)) || {
  for i in "${missing[@]}"; do
    echo "FAIL  no ${names[i]}: ${queries[i]}"
  done
  exit 1
}

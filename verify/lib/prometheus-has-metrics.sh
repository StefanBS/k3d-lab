#!/usr/bin/env bash
# Checks that Prometheus holds the metrics Alloy scrapes on every Ready node, the GPU
# Node included when it's Joined, and kube-state-metrics' from wherever it runs. Each is
# an `up` series at 1: Alloy scraped the target and remote-wrote the result.
# Alloy scrapes every 30s, so a new Lab's first samples take a while: it retries for 2m.
# Run by metrics-reach-prometheus, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail

# The jobs Alloy scrapes on each node (platform/alloy/values.yaml).
node_jobs=(kubelet cadvisor node-exporter)

# Usage: query <PromQL> <yq expression>
# Runs the query through the API server's proxy to Prometheus' Service, and prints what
# the yq expression makes of the JSON response.
query() {
  local promql=$1 expression=$2 encoded
  encoded=$(Q=$promql yq -n 'strenv(Q) | @uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:http/proxy/api/v1/query?query=$encoded" |
    yq -p json "$expression"
}

nodes=$("$(dirname "$0")/ready-nodes.sh")
[[ -n $nodes ]] || {
  echo "FAIL  no Ready nodes"
  exit 1
}

for attempt in {1..24}; do
  missing=()
  # "<node> <job>" for every target that's up.
  up_targets=$(query 'up == 1' '.data.result[].metric | .node + " " + .job' 2>&1) || up_targets=""
  for node in $nodes; do
    for job in "${node_jobs[@]}"; do
      grep -qx "$node $job" <<<"$up_targets" || missing+=("$node: $job")
    done
  done
  grep -q ' kube-state-metrics$' <<<"$up_targets" || missing+=("kube-state-metrics")
  ((${#missing[@]})) || break
  ((attempt < 24)) && sleep 5
done

for node in $nodes; do
  [[ " ${missing[*]} " == *" $node: "* ]] || echo "OK    $node"
done
((${#missing[@]} == 0)) || {
  printf 'FAIL  no metrics from %s\n' "${missing[@]}"
  exit 1
}
echo "OK    kube-state-metrics"

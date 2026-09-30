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

# Prints the result of a PromQL query as "<label values>" lines, through the API server's
# proxy to Prometheus' Service.
query() {
  local encoded
  encoded=$(Q=$1 yq -n 'strenv(Q) | @uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:http/proxy/api/v1/query?query=$encoded" |
    yq -p json "$2"
}

nodes=$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
  awk '$2 == "True" { print $1 }')
[[ -n $nodes ]] || {
  echo "FAIL  no Ready nodes"
  exit 1
}

for attempt in {1..24}; do
  missing=()
  # "<node> <job>" for every target that's up.
  up=$(query 'up == 1' '.data.result[].metric | .node + " " + .job' 2>&1) || up=""
  for node in $nodes; do
    for job in "${node_jobs[@]}"; do
      grep -qx "$node $job" <<<"$up" || missing+=("$node: $job")
    done
  done
  grep -q ' kube-state-metrics$' <<<"$up" || missing+=("kube-state-metrics")
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

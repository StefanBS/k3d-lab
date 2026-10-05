#!/usr/bin/env bash
# Checks that Prometheus holds the metrics Alloy scrapes on every Ready node, the GPU
# Node included when it's Joined, and kube-state-metrics' from wherever it runs. Each is
# an `up` series at 1: Alloy scraped the target and remote-wrote the result.
# Alloy scrapes every 30s, so a new Lab's first samples take a while: it retries for 2m.
# Run by metrics-reach-prometheus, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

# The jobs Alloy scrapes on each node (platform/alloy/values.yaml).
node_jobs=(kubelet cadvisor node-exporter)

# Prints "<node>: <job>" for each node's target that isn't up yet, and
# kube-state-metrics if it isn't.
missing_metrics() {
  local up_targets node job
  # "<node> <job>" for every target that's up.
  up_targets=$(prometheus_query 'up == 1' '.data.result[].metric | .node + " " + .job' 2>&1) || up_targets=""
  for node in "${nodes[@]}"; do
    for job in "${node_jobs[@]}"; do
      grep -qx "$node $job" <<<"$up_targets" || echo "$node: $job"
    done
  done
  grep -q ' kube-state-metrics$' <<<"$up_targets" || echo kube-state-metrics
}

require_ready_nodes
eventually 'no metrics from %s' "${nodes[@]}" kube-state-metrics -- missing_metrics

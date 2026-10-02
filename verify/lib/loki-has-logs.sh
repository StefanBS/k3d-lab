#!/usr/bin/env bash
# Usage: loki-has-logs.sh <namespace>
# Checks that Loki holds, for every Ready node, the GPU Node included when it's Joined,
# the line the probe client in the namespace logged there as it started (probes.yaml),
# with the labels Alloy gives it on that node.
# Alloy ships logs within seconds, but Loki makes them searchable a little later: it
# retries for 2m.
# Run by logs-reach-loki, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

namespace=$1

# Usage: query <LogQL>
# Runs the query against Loki, over the last hour, and prints the lines it found, one per
# line. The chart names Loki's one HTTP port, API included, http-metrics.
query() {
  monitoring_get loki:http-metrics "loki/api/v1/query_range?query=$(uri_encode "$1")" |
    yq -p json '.data.result[].values[][1]'
}

# Prints each node whose line Loki doesn't hold yet.
missing_logs() {
  local node line found
  for node in "${nodes[@]}"; do
    line="k3d-lab probe on $node"
    found=$(query "{namespace=\"$namespace\", container=\"client\", node=\"$node\"} |= \"$line\"" 2>&1) || found=""
    grep -qxF "$line" <<<"$found" || echo "$node"
  done
}

require_ready_nodes
retry missing_logs
report 'no logs from %s' "${nodes[@]}"

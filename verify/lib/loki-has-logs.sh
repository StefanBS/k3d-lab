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

namespace=$1

# Usage: query <LogQL>
# Runs the query through the API server's proxy to Loki's Service, over the last hour,
# and prints the lines it found, one per line. The chart names Loki's one HTTP port,
# API included, http-metrics.
query() {
  local encoded
  encoded=$(Q=$1 yq -n 'strenv(Q) | @uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/loki:http-metrics/proxy/loki/api/v1/query_range?query=$encoded" |
    yq -p json '.data.result[].values[][1]'
}

nodes=$("$(dirname "$0")/ready-nodes.sh")
[[ -n $nodes ]] || {
  echo "FAIL  no Ready nodes"
  exit 1
}

for attempt in {1..24}; do
  missing=()
  for node in $nodes; do
    line="k3d-lab probe on $node"
    found=$(query "{namespace=\"$namespace\", container=\"client\", node=\"$node\"} |= \"$line\"" 2>&1) || found=""
    grep -qxF "$line" <<<"$found" || missing+=("$node")
  done
  ((${#missing[@]})) || break
  ((attempt < 24)) && sleep 5
done

for node in $nodes; do
  [[ " ${missing[*]} " == *" $node "* ]] || echo "OK    $node"
done
((${#missing[@]} == 0)) || {
  printf 'FAIL  no logs from %s\n' "${missing[@]}"
  exit 1
}

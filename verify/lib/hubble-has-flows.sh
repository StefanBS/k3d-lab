#!/usr/bin/env bash
# Checks that Hubble Relay returns flows from every Ready node, the GPU Node included
# when it's Joined: each node's Hubble is connected to the relay and has seen traffic.
# Run by hubble-healthy, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

# Prints each node the relay returns no flow from yet.
nodes_without_flows() {
  local node
  for node in "${nodes[@]}"; do
    hubble_observe --node-name "$node" --last 1 -o compact 2>/dev/null | grep -q . || echo "$node"
  done
}

require_ready_nodes
eventually 'Hubble Relay returns no flows from %s' "${nodes[@]}" -- nodes_without_flows

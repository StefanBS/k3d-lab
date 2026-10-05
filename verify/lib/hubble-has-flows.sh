#!/usr/bin/env bash
# Checks that Hubble Relay returns flows from every Ready node, the GPU Node included
# when it's Joined: each node's Hubble is connected to the relay and has seen traffic.
# The relay has no hubble CLI, so it's asked from a cilium-agent, which has one. The
# agent runs on the host network, where cluster DNS doesn't resolve, so the relay is
# reached at its ClusterIP.
# Run by hubble-healthy, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

relay=$(kubectl -n kube-system get service hubble-relay -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')

# Prints each node the relay returns no flow from yet.
nodes_without_flows() {
  local node
  for node in "${nodes[@]}"; do
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
      hubble observe --server "$relay" --node-name "$node" --last 1 -o compact 2>/dev/null |
      grep -q . || echo "$node"
  done
}

require_ready_nodes
eventually 'Hubble Relay returns no flows from %s' "${nodes[@]}" -- nodes_without_flows

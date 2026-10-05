#!/usr/bin/env bash
# Usage: policy-denies.sh <check namespace>
# Checks that the Workloads' network policies deny what they don't allow, both ways:
# - out: the probe in each Workload namespace (workload-probes.yaml) can't reach the web
#   probe in the check's namespace;
# - in: the check's client can't reach podinfo directly, at its pod's address.
# Each attempt must fail, and Hubble must record it as DROPPED by policy, so a request
# that fails for any other reason, such as a pod that isn't up, doesn't count.
# Run by network-policy-enforced, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

namespace=$1
workload_namespaces=(rollouts-demo comfyui)

# Usage: hubble_denied <hubble observe filters>...
# Succeeds once Hubble Relay holds a flow matching the filters that was dropped by policy.
# The agent that dropped it reports it within a few seconds.
hubble_denied() {
  local attempt
  for attempt in {1..10}; do
    hubble_observe --verdict DROPPED --since 5m -o jsonpb "$@" 2>/dev/null |
      grep -Eq '"drop_reason_desc":"POLICY_DEN(IED|Y)"' && return 0
    ((attempt == 10)) || sleep 3
  done
  return 1
}

# Usage: expect_denied <description> <namespace> <pod> <address> <destination pod>
# Says OK if the pod's request to http://<address>/ fails and Hubble records it, from
# the pod to <destination pod> (namespace/name), as dropped by policy. Otherwise says
# FAIL, and why, and fails.
expect_denied() {
  local what=$1 ns=$2 pod=$3 address=$4 to=$5
  if kubectl -n "$ns" exec "$pod" -- wget -qO /dev/null -T 3 "http://$address/" 2>/dev/null; then
    echo "FAIL  $what: allowed"
    return 1
  fi
  if ! hubble_denied --from-pod "$ns/$pod" --to-pod "$to"; then
    echo "FAIL  $what: failed, but Hubble has no drop by policy"
    return 1
  fi
  echo "OK    $what: dropped by policy"
}

web_pod=$(kubectl -n "$namespace" get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
web_ip=$(kubectl -n "$namespace" get pod "$web_pod" -o jsonpath='{.status.podIP}')
client=$(kubectl -n "$namespace" get pods -l app=client -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$namespace" wait --for=condition=Ready "pod/$client" --timeout=1m >/dev/null
podinfo=$(kubectl -n rollouts-demo get pods -l app=rollouts-demo -o jsonpath='{.items[0].metadata.name}')
podinfo_ip=$(kubectl -n rollouts-demo get pod "$podinfo" -o jsonpath='{.status.podIP}')

bad=0
for ns in "${workload_namespaces[@]}"; do
  kubectl -n "$ns" wait --for=condition=Ready pod/network-policy-probe --timeout=1m >/dev/null
  expect_denied "$ns to another namespace" "$ns" network-policy-probe "$web_ip" \
    "$namespace/$web_pod" || bad=1
done
expect_denied "another namespace to rollouts-demo" "$namespace" "$client" "$podinfo_ip:9898" \
  "rollouts-demo/$podinfo" || bad=1
exit "$bad"

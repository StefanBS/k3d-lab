#!/usr/bin/env bash
# Usage: workload-network-baseline.sh <check namespace>
# Checks what the Platform's tiers of network policy give a Workload that writes none
# (platform/workload-network-policy, ADR 0008), in three throwaway namespaces labelled
# as the workloads ApplicationSet labels a Workload's, each with baseline-workload.yaml:
# - <check namespace>-baseline, with the same-namespace allow, as a Workload gets it,
#   and baseline-exposed.yaml: podinfo answers the Host through the Gateway, the client
#   reaches it, the client can't reach the web probe in the check's namespace, and a
#   client in the check's namespace can't reach podinfo directly, at its pod's address;
# - <check namespace>-strict, `isolation: strict`, so without the same-namespace allow:
#   the client can't reach podinfo;
# - <check namespace>-guardrail, with the same-namespace allow and a policy of its own
#   allowing the kube-apiserver (baseline-apiserver-allow.yaml): the client still can't
#   reach it.
# Each denial must also show in Hubble as DROPPED by policy. workload-scraped checks that
# Alloy scrapes such a Workload, in a Lab with Alloy.
# Run by workload-network-baseline, whose script steps point kubectl at the Lab through
# a context named chainsaw. verify.sh exports LAB_CA_CERT.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

namespace=$1
lib=$(dirname "$0")
same_namespace=$lib/../../platform/workload-network-policy/same-namespace
exposed=$namespace-baseline
strict=$namespace-strict
guardrail=$namespace-guardrail

# Created here, not by Chainsaw, like network-policy-enforced's probes, and deleted on
# the way out, however the script ends.
# shellcheck disable=SC2329 # Run by the trap below.
delete_namespaces() {
  kubectl delete namespace "$exposed" "$strict" "$guardrail" --ignore-not-found --wait=false >/dev/null
}
trap delete_namespaces EXIT
# A run that died before its trap leaves its namespaces behind, each with an HTTPRoute
# on the Gateway. Their names never repeat, so this doesn't wait for them to go.
kubectl delete namespace -l k3d-lab/verify=workload-network-baseline --wait=false >/dev/null

create_workload_namespace "$exposed" workload-network-baseline
create_workload_namespace "$strict" workload-network-baseline k3d-lab/isolation=strict
create_workload_namespace "$guardrail" workload-network-baseline
kubectl -n "$exposed" apply -f "$same_namespace" >/dev/null
kubectl -n "$guardrail" apply -f "$same_namespace" >/dev/null
host=$exposed.lab.localhost
HOST=$host yq '(select(.kind == "HTTPRoute") | .spec.hostnames) = [strenv(HOST)]' \
  "$lib/baseline-exposed.yaml" | kubectl -n "$exposed" apply -f - >/dev/null
kubectl -n "$guardrail" apply -f "$lib/baseline-apiserver-allow.yaml" >/dev/null

for ns in "$exposed" "$strict" "$guardrail"; do
  kubectl -n "$ns" wait --for=condition=Available deployment/podinfo --timeout=2m >/dev/null
  kubectl -n "$ns" wait --for=condition=Ready pod/client --timeout=1m >/dev/null
done

# Usage: podinfo_pod <namespace>
podinfo_pod() { kubectl -n "$1" get pods -l app=podinfo -o jsonpath='{.items[0].metadata.name}'; }

bad=0

# The Gateway takes a few seconds to route a new HTTPRoute.
if curl -sS --fail --retry 10 --retry-all-errors --retry-delay 3 --cacert "$LAB_CA_CERT" \
  -o /dev/null "https://$host/"; then
  echo "OK    $exposed answers through the Gateway at https://$host"
else
  echo "FAIL  $exposed doesn't answer through the Gateway at https://$host"
  bad=1
fi

exposed_pod=$(podinfo_pod "$exposed")
if kubectl -n "$exposed" exec client -- wget -qO /dev/null -T 3 "http://$(pod_ip "$exposed" "$exposed_pod"):9898/"; then
  echo "OK    $exposed's pods reach each other"
else
  echo "FAIL  $exposed's pods don't reach each other"
  bad=1
fi

web_pod=$(kubectl -n "$namespace" get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
expect_denied "$exposed to another namespace" "$exposed" client "http://$(pod_ip "$namespace" "$web_pod")/" \
  --to-pod "$namespace/$web_pod" || bad=1

# From a namespace with no policy of its own, so only podinfo's side can drop it. The
# client is the one on a Ready node: a Joined GPU Node may be powered off.
require_ready_nodes
other_client=$(node_pod "$namespace" app=client "${nodes[0]}")
kubectl -n "$namespace" wait --for=condition=Ready "pod/$other_client" --timeout=1m >/dev/null
expect_denied "another namespace to $exposed" "$namespace" "$other_client" \
  "http://$(pod_ip "$exposed" "$exposed_pod"):9898/" --to-pod "$exposed/$exposed_pod" || bad=1

strict_pod=$(podinfo_pod "$strict")
expect_denied "$strict's pods to each other" "$strict" client "http://$(pod_ip "$strict" "$strict_pod"):9898/" \
  --to-pod "$strict/$strict_pod" || bad=1

# At its ClusterIP, which Cilium translates to the Server's address before policy. Only
# a deny rule's drop counts: the default-deny's would mean the allow never applied.
apiserver=$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')
server=$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
DENIED_BY=POLICY_DENY expect_denied "$guardrail to the kube-apiserver, despite its own allow" \
  "$guardrail" client "https://$apiserver/" --to-ip "$server" || bad=1
exit "$bad"

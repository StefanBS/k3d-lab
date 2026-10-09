#!/usr/bin/env bash
# Usage: workload-network-baseline.sh <check namespace>
# Checks what the Platform's tiers of network policy give a Workload that writes none
# (platform/workload-network-policy, ADR 0008), in three throwaway namespaces labelled
# as the workloads ApplicationSet labels a Workload's, each with baseline-workload.yaml:
# - <check namespace>-baseline, with the same-namespace allow, as a Workload gets it,
#   and baseline-exposed.yaml: podinfo answers the Host through the Gateway, Alloy
#   scrapes it, the client reaches it, and the client can't reach the web probe in the
#   check's namespace;
# - <check namespace>-strict, `isolation: strict`, so without the same-namespace allow:
#   the client can't reach podinfo;
# - <check namespace>-guardrail, with the same-namespace allow and a policy of its own
#   allowing the kube-apiserver (baseline-apiserver-allow.yaml): the client still can't
#   reach it.
# Each denial must also show in Hubble as DROPPED by policy. The namespaces are also
# labelled k3d-lab/verify, so network-policy-enforced doesn't take them for Workloads'.
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

# Usage: create_namespace <name> [<label>=<value>...]
create_namespace() {
  local ns=$1
  shift
  kubectl create namespace "$ns" >/dev/null
  kubectl label namespace "$ns" k3d-lab/group=workloads k3d-lab/verify=workload-network-baseline \
    "$@" >/dev/null
  kubectl -n "$ns" apply -f "$lib/baseline-workload.yaml" >/dev/null
}
create_namespace "$exposed"
create_namespace "$strict" k3d-lab/isolation=strict
create_namespace "$guardrail"
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
# Usage: pod_ip <namespace> <pod>
pod_ip() { kubectl -n "$1" get pod "$2" -o jsonpath='{.status.podIP}'; }

bad=0

# The Gateway takes a few seconds to route a new HTTPRoute.
if curl -sS --fail --retry 10 --retry-all-errors --retry-delay 3 --cacert "$LAB_CA_CERT" \
  -o /dev/null "https://$host/"; then
  echo "OK    $exposed answers through the Gateway at https://$host"
else
  echo "FAIL  $exposed doesn't answer through the Gateway at https://$host"
  bad=1
fi

scraped="Alloy scrapes podinfo in $exposed"
# Prints $scraped until Alloy's last scrape of podinfo there succeeded.
# shellcheck disable=SC2329 # Run by eventually.
not_scraped() {
  [[ $(prometheus_query "max(up{namespace=\"$exposed\"})" '.data.result[0].value[1] // ""') == 1 ]] ||
    echo "$scraped"
}
eventually '%s: no successful scrape' "$scraped" -- not_scraped || bad=1

pod=$(podinfo_pod "$exposed")
if kubectl -n "$exposed" exec client -- wget -qO /dev/null -T 3 "http://$(pod_ip "$exposed" "$pod"):9898/"; then
  echo "OK    $exposed's pods reach each other"
else
  echo "FAIL  $exposed's pods don't reach each other"
  bad=1
fi

web_pod=$(kubectl -n "$namespace" get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
expect_denied "$exposed to another namespace" "$exposed" client "http://$(pod_ip "$namespace" "$web_pod")/" \
  --to-pod "$namespace/$web_pod" || bad=1

pod=$(podinfo_pod "$strict")
expect_denied "$strict's pods to each other" "$strict" client "http://$(pod_ip "$strict" "$pod"):9898/" \
  --to-pod "$strict/$pod" || bad=1

# At its ClusterIP, which Cilium translates to the Server's address before policy. Only
# a deny rule's drop counts: the default-deny's would mean the allow never applied.
apiserver=$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')
server=$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
DENIED_BY=POLICY_DENY expect_denied "$guardrail to the kube-apiserver, despite its own allow" \
  "$guardrail" client "https://$apiserver/" --to-ip "$server" || bad=1
exit "$bad"

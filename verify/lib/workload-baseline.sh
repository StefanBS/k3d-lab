#!/usr/bin/env bash
# Usage: workload-baseline.sh <check namespace>
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
#   allowing the kube-apiserver (baseline-own-policy.yaml): the client still can't
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
open=$namespace-baseline
strict=$namespace-strict
guarded=$namespace-guardrail

# Created here, not by Chainsaw, like network-policy-enforced's probes, and deleted on
# the way out, however the script ends.
# shellcheck disable=SC2329 # Run by the trap below.
delete_namespaces() {
  kubectl delete namespace "$open" "$strict" "$guarded" --ignore-not-found --wait=false >/dev/null
}
trap delete_namespaces EXIT

# Usage: create_namespace <name> [<label>=<value>...]
create_namespace() {
  local ns=$1
  shift
  kubectl create namespace "$ns" >/dev/null
  kubectl label namespace "$ns" k3d-lab/group=workloads k3d-lab/verify=workload-network-baseline \
    "$@" >/dev/null
  kubectl -n "$ns" apply -f "$lib/baseline-workload.yaml" >/dev/null
}
create_namespace "$open"
create_namespace "$strict" k3d-lab/isolation=strict
create_namespace "$guarded"
kubectl -n "$open" apply -f "$same_namespace" >/dev/null
kubectl -n "$guarded" apply -f "$same_namespace" >/dev/null
host=$open.lab.localhost
HOST=$host yq '(select(.kind == "HTTPRoute") | .spec.hostnames) = [strenv(HOST)]' \
  "$lib/baseline-exposed.yaml" | kubectl -n "$open" apply -f - >/dev/null
kubectl -n "$guarded" apply -f "$lib/baseline-own-policy.yaml" >/dev/null

for ns in "$open" "$strict" "$guarded"; do
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
  echo "OK    $open answers through the Gateway at https://$host"
else
  echo "FAIL  $open doesn't answer through the Gateway at https://$host"
  bad=1
fi

scraped="Alloy scrapes podinfo in $open"
# Prints $scraped until Alloy's last scrape of podinfo there succeeded.
# shellcheck disable=SC2329 # Run by eventually.
not_scraped() {
  [[ $(prometheus_query "max(up{namespace=\"$open\"})" '.data.result[0].value[1] // ""') == 1 ]] ||
    echo "$scraped"
}
eventually '%s: no successful scrape' "$scraped" -- not_scraped || bad=1

pod=$(podinfo_pod "$open")
if kubectl -n "$open" exec client -- wget -qO /dev/null -T 3 "http://$(pod_ip "$open" "$pod"):9898/"; then
  echo "OK    $open's pods reach each other"
else
  echo "FAIL  $open's pods don't reach each other"
  bad=1
fi

web_pod=$(kubectl -n "$namespace" get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
expect_denied "$open to another namespace" "$open" client "http://$(pod_ip "$namespace" "$web_pod")/" \
  --to-pod "$namespace/$web_pod" || bad=1

pod=$(podinfo_pod "$strict")
expect_denied "$strict's pods to each other" "$strict" client "http://$(pod_ip "$strict" "$pod"):9898/" \
  --to-pod "$strict/$pod" || bad=1

# At its ClusterIP, which Cilium translates to the Server's address before policy.
apiserver=$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')
expect_denied "$guarded to the kube-apiserver, despite its own allow" "$guarded" client \
  "https://$apiserver/" || bad=1
exit "$bad"

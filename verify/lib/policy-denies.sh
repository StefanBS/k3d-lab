#!/usr/bin/env bash
# Usage: policy-denies.sh <check namespace>
# Checks that the Workloads' network policies deny what they don't allow, outbound: a
# probe in each Workload namespace (workload-probes.yaml) can't reach the web probe in
# the check's namespace. The Workload namespaces are the ones labelled
# k3d-lab/group=workloads, which the Platform sets: first, it checks those are exactly
# the namespaces of the Workloads' Applications.
# Each attempt must fail, and Hubble must record it as DROPPED by policy, so a request
# that fails for any other reason, such as a pod that isn't up, doesn't count.
# Inbound, a Lab may have no Workload with a pod to aim at, so workload-network-baseline
# checks that against a namespace of its own.
# Run by network-policy-enforced, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

namespace=$1
# Leaves out the namespaces workload-network-baseline labels as a Workload's for its
# own run, which it labels k3d-lab/verify.
mapfile -t workload_namespaces < <(kubectl get namespaces -l 'k3d-lab/group=workloads,!k3d-lab/verify' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
# The Platform labels exactly the namespaces of the Workloads' Applications.
expected=$(kubectl -n argocd get applications -l k3d-lab/group=workloads \
  -o jsonpath='{range .items[*]}{.spec.destination.namespace}{"\n"}{end}' | sort -u)
labelled=$(printf '%s\n' "${workload_namespaces[@]}" | sort)
if [[ -z $expected || $labelled != "$expected" ]]; then
  echo "FAIL  the namespaces labelled k3d-lab/group=workloads aren't the Workloads' ones:"
  diff <(echo "$labelled") <(echo "$expected") | sed -n 's/^</  labelled, no Workload:/p; s/^>/  a Workload'"'"'s, not labelled:/p'
  exit 1
fi
echo "OK    the Workloads' namespaces, and only theirs, are labelled k3d-lab/group=workloads"

# The probes are applied here, not by Chainsaw, which only knows the namespaces it's
# told. They're deleted on the way out, however the script ends.
probes=$(dirname "$0")/workload-probes.yaml
# shellcheck disable=SC2329 # Run by the trap below.
delete_probes() {
  local ns
  for ns in "${workload_namespaces[@]}"; do
    kubectl -n "$ns" delete -f "$probes" --ignore-not-found --wait=false >/dev/null
  done
}
trap delete_probes EXIT
for ns in "${workload_namespaces[@]}"; do
  # A run that died before its trap leaves a probe behind. One from an older
  # workload-probes.yaml can't be changed, and one still being deleted would take the
  # applied one with it, so this waits for it to go.
  kubectl -n "$ns" delete -f "$probes" --ignore-not-found --timeout=1m >/dev/null
  kubectl -n "$ns" apply -f "$probes" >/dev/null
done

web_pod=$(kubectl -n "$namespace" get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
web_ip=$(kubectl -n "$namespace" get pod "$web_pod" -o jsonpath='{.status.podIP}')

bad=0
for ns in "${workload_namespaces[@]}"; do
  kubectl -n "$ns" wait --for=condition=Ready pod/network-policy-probe --timeout=1m >/dev/null
  expect_denied "$ns to another namespace" "$ns" network-policy-probe "http://$web_ip/" \
    --to-pod "$namespace/$web_pod" || bad=1
done
exit "$bad"

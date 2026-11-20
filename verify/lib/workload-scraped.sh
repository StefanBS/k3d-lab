#!/usr/bin/env bash
# Usage: workload-scraped.sh <check namespace>
# Checks that Alloy scrapes a Workload that writes no network policy of its own
# (platform/workload-network-policy, ADR 0008), in a throwaway namespace labelled as the
# workloads ApplicationSet labels a Workload's, with baseline-workload.yaml and
# baseline-podmonitor.yaml: Prometheus gets podinfo's `up` at 1, which only a successful
# scrape gives.
# Run by workload-scraped, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

scraped=$1-scraped

# Created here, not by Chainsaw, so it's labelled as a Workload's, and deleted on the way
# out, however the script ends.
# shellcheck disable=SC2329 # Run by the trap below.
delete_namespace() { kubectl delete namespace "$scraped" --ignore-not-found --wait=false >/dev/null; }
trap delete_namespace EXIT
# A run that died before its trap leaves its namespace behind. Its name never repeats, so
# this doesn't wait for it to go.
kubectl delete namespace -l k3d-lab/verify=workload-scraped --wait=false >/dev/null

create_workload_namespace "$scraped" workload-scraped
kubectl -n "$scraped" apply -f "$(dirname "$0")/baseline-podmonitor.yaml" >/dev/null
kubectl -n "$scraped" wait --for=condition=Available deployment/podinfo --timeout=2m >/dev/null

what="Alloy scrapes podinfo in $scraped"
# Prints $what until Alloy's last scrape of podinfo there succeeded.
# shellcheck disable=SC2329 # Run by eventually.
not_scraped() {
  [[ $(prometheus_query "max(up{namespace=\"$scraped\"})" '.data.result[0].value[1] // ""') == 1 ]] ||
    echo "$what"
}
eventually '%s: no successful scrape' "$what" -- not_scraped

#!/usr/bin/env bash
# Checks that podinfo receives the load generator's requests through the Gateway
# (workloads/rollouts-demo/load.yaml), from its own metrics in Prometheus. Without them,
# a canary's analysis has nothing to measure. The load sends 5 per second; more than 1
# is enough to say it gets through.
# podinfo is scraped every 10s, and a rate needs two samples: it retries for 2m.
# Run by demo-rollout-healthy, whose script steps point kubectl at the Lab through a
# context named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

# Prints "load" while podinfo receives less than 1 request per second.
missing_load() {
  local rate
  rate=$(prometheus_query 'sum(rate(http_requests_total{namespace="rollouts-demo"}[1m]))' \
    '.data.result[0].value[1] // 0' 2>&1) || rate=0
  awk -v r="$rate" 'BEGIN { exit !(r > 1) }' || echo load
}

eventually 'podinfo receives no %s through the Gateway' load -- missing_load

#!/bin/sh
# Usage: sh -c "$(cat send-trace.sh)" send-trace <namespace>
# Runs in a probe client pod (busybox, not the Host): sends Alloy one trace over OTLP
# HTTP, as a call from the service <namespace>-client to the service <namespace>-web.
# Its ID is the MD5 of <namespace>/<node>, so tempo-has-traces.sh finds it without
# being told. The service names are new with each check's namespace, so the service
# graph prometheus-has-trace-metrics.sh finds for them can only come from this run.
# Both scripts derive the same ID and names: change them together.
# Run by traces-reach-tempo, through on-ready-nodes.sh.
set -eu

namespace=$1
trace=$(printf '%s/%s' "$namespace" "$NODE_NAME" | md5sum | cut -c1-32)
client_span=$(echo "$trace" | cut -c1-16)
web_span=$(echo "$trace" | cut -c17-32)
start=$(($(date +%s) * 1000000000))
end=$((start + 100000000))

# Usage: resource_spans <service> <span ID> <parent span ID> <span kind>
# One service's span. Kinds 2 and 3 are SERVER and CLIENT: Tempo pairs a CLIENT span
# with its SERVER child into an edge of the service graph.
resource_spans() {
  cat <<JSON
{"resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "$1"}}]},
 "scopeSpans": [{"scope": {"name": "k3d-lab-verify"}, "spans": [{
   "traceId": "$trace", "spanId": "$2", "parentSpanId": "$3", "kind": $4, "name": "GET /",
   "startTimeUnixNano": "$start", "endTimeUnixNano": "$end"}]}]}
JSON
}

body="{\"resourceSpans\": [
$(resource_spans "$namespace-client" "$client_span" "" 3),
$(resource_spans "$namespace-web" "$web_span" "$client_span" 2)
]}"
# Right after `just up`, with every check starting at once, Alloy can take more than 5s
# to answer, so it gets 3 tries. A try that timed out may still have arrived, and
# Tempo keeps both copies: tempo-has-traces.sh allows for that.
for attempt in 1 2 3; do
  wget -qO- -T 5 --header 'Content-Type: application/json' --post-data "$body" \
    http://alloy.monitoring.svc:4318/v1/traces && exit 0
  [ "$attempt" = 3 ] || sleep 2
done
exit 1

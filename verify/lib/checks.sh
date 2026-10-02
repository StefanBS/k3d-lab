# Sourced by the checks' scripts in verify/lib: what they share about nodes, pods,
# retrying and reporting. Their script steps point kubectl at the Lab through a context
# named chainsaw, so this calls plain kubectl, not scripts/lib.sh's kc (ADR 0004).
# shellcheck shell=bash

# A command that fails inside $(...) fails it, as it would outside, so a broken check
# stops its script rather than passing.
shopt -s inherit_errexit

# Sets nodes to the name of every Ready node, the GPU Node included when it's Joined and
# powered on. Otherwise, says so and exits.
require_ready_nodes() {
  local ready
  ready=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
    awk '$2 == "True" { print $1 }')
  [[ -n $ready ]] || {
    echo "FAIL  no Ready nodes"
    exit 1
  }
  # shellcheck disable=SC2034 # The scripts that source this read nodes.
  mapfile -t nodes <<<"$ready"
}

# Usage: node_pod <namespace> <pod selector> <node>
# Prints the name of the pod matching the selector on the node, or nothing if there's
# none yet. Skips pods being deleted: while a pod is replaced, the node briefly has two.
node_pod() {
  kubectl -n "$1" get pods -l "$2" --field-selector "spec.nodeName=$3" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}' |
    awk 'NF == 1 { print $1; exit }'
}

# Usage: monitoring_get <service>:<port> <path>
# Prints what a Service in the monitoring namespace answers at the path, through the
# API server's proxy to it.
monitoring_get() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/$1/proxy/$2"
}

# Usage: uri_encode <text>
# Prints the text encoded for a URL's query string.
uri_encode() {
  Q=$1 yq -n 'strenv(Q) | @uri'
}

# Usage: prometheus_query <PromQL> <yq expression>
# Runs the query against Prometheus, and prints what the yq expression makes of the JSON
# response.
prometheus_query() {
  monitoring_get prometheus-server:http "api/v1/query?query=$(uri_encode "$1")" | yq -p json "$2"
}

# Usage: retry <command>...
# Runs the command until it prints nothing: each line it prints is something it didn't
# find yet. Leaves what it printed last in the array missing, and exits if it fails.
# Tries 24 times, 5s apart: 2m, within the exec timeout (.chainsaw.yaml).
retry() {
  local attempt out
  for attempt in {1..24}; do
    out=$("$@")
    [[ -n $out ]] || {
      missing=()
      return 0
    }
    mapfile -t missing <<<"$out"
    ((attempt == 24)) || sleep 5
  done
}

# Usage: report <printf format> <target>...
# After retry: says OK for each target nothing is missing from, then FAIL for each line
# in missing, through the format. A line is missing from a target when it's the target
# itself, or starts with "<target>: ". Fails if anything is missing.
report() {
  local format=$1 target line ok
  shift
  for target; do
    ok=1
    for line in "${missing[@]}"; do
      [[ $line == "$target" || $line == "$target: "* ]] && ok=0
    done
    ((ok)) && echo "OK    $target"
  done
  for line in "${missing[@]}"; do
    # shellcheck disable=SC2059 # The format is the caller's.
    printf "FAIL  $format\n" "$line"
  done
  ((${#missing[@]} == 0))
}

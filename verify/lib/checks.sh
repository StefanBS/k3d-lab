# Sourced by the checks' scripts in verify/lib: what they share about nodes, pods,
# retrying and reporting. Their script steps point kubectl at the Lab through a context
# named chainsaw, so this calls plain kubectl, not scripts/lib.sh's kc (ADR 0004).
# shellcheck shell=bash

# Run by hand, plain kubectl would act on whatever cluster the current context names,
# which may not be the Lab. So a script only runs under Chainsaw: `just verify <check>`,
# with VERBOSE=1 to see each of its OK lines.
if [[ $(kubectl config current-context 2>/dev/null) != chainsaw ]]; then
  echo "FAIL  kubectl isn't pointed at the Lab by Chainsaw; run this through 'just verify <check>'"
  exit 1
fi

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

# Usage: eventually <printf format> <target>... -- <command>...
# Runs the command until it prints nothing: each line it prints is something it didn't
# find yet. Tries 24 times, 5s apart: 2m, within the exec timeout (.chainsaw.yaml).
# Then says OK for each target nothing is missing from, and FAIL for each line the
# command printed last, through the format. A line is missing from a target when it's
# the target itself, or starts with "<target>: ". Fails if anything is missing.
eventually() {
  local format=$1 targets=() missing=() attempt out target line ok
  shift
  while [[ $1 != -- ]]; do
    targets+=("$1")
    shift
  done
  shift
  for attempt in {1..24}; do
    out=$("$@")
    [[ -n $out ]] || {
      missing=()
      break
    }
    mapfile -t missing <<<"$out"
    ((attempt == 24)) || sleep 5
  done
  for target in "${targets[@]}"; do
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

# Usage: hubble_observe <hubble observe args>...
# Runs `hubble observe` against Hubble Relay, which gathers every node's flows. The relay
# has no hubble CLI, so it's asked from a cilium-agent, which has one. The agent runs on
# the host network, where cluster DNS doesn't resolve, so the relay is reached at its
# ClusterIP.
hubble_observe() {
  local relay
  relay=$(kubectl -n kube-system get service hubble-relay -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --server "$relay" "$@"
}

# Usage: [DENIED_BY=POLICY_DENY] hubble_denied <hubble observe filters>...
# Succeeds once Hubble Relay holds a flow matching the filters that was dropped by
# policy: for want of an allow (POLICY_DENIED) or by a deny rule (POLICY_DENY), or only
# the one DENIED_BY names. The agent that dropped it reports it within a few seconds.
hubble_denied() {
  local attempt reason=${DENIED_BY:-POLICY_DEN(IED|Y)}
  for attempt in {1..10}; do
    hubble_observe --verdict DROPPED --since 5m -o jsonpb "$@" 2>/dev/null |
      grep -Eq "\"drop_reason_desc\":\"$reason\"" && return 0
    ((attempt == 10)) || sleep 3
  done
  return 1
}

# Usage: [DENIED_BY=POLICY_DENY] expect_denied <description> <namespace> <pod> <url> <hubble observe filters>...
# Says OK if the pod's request to the URL, with busybox's wget, fails and Hubble records
# a flow from the pod matching the filters as dropped by policy. Otherwise says FAIL,
# and why, and fails. The drop is what proves the policy denied it: a request that
# fails for any other reason, such as a pod that isn't up, leaves none.
expect_denied() {
  local what=$1 ns=$2 pod=$3 url=$4
  shift 4
  if kubectl -n "$ns" exec "$pod" -- wget -qO /dev/null -T 3 "$url" 2>/dev/null; then
    echo "FAIL  $what: allowed"
    return 1
  fi
  if ! hubble_denied --from-pod "$ns/$pod" "$@"; then
    echo "FAIL  $what: failed, but Hubble has no drop by policy"
    return 1
  fi
  echo "OK    $what: dropped by policy"
}

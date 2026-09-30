#!/usr/bin/env bash
# Checks how the running Lab behaves, as one named PASS/FAIL line per check.
# Exits non-zero if any check fails.
#
# Check functions run inside `if`, where `set -e` doesn't apply: every step that can
# fail must return explicitly.
# shellcheck disable=SC2329  # check functions are called indirectly, through check()
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Runs a check function, printing PASS, or FAIL and the end of what it printed.
check() {
  local name=$1 out
  shift
  if out=$("$@" 2>&1); then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

# Prints "<node> <Ready status>" per node matching the optional label selector.
node_readiness() {
  kc get nodes ${1:+-l "$1"} \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
}

# Prints the name of every Ready node. With none, says why on stderr and fails.
ready_nodes() {
  local nodes
  nodes=$(node_readiness | awk '$2 == "True" { print $1 }') || return 1
  [[ -n $nodes ]] || {
    echo "no Ready nodes" >&2
    return 1
  }
  echo "$nodes"
}

# Waits for the pod with the given label on the given node to be Ready, and prints its
# name. Otherwise, says why on stderr and fails.
wait_pod_on_node() {
  local namespace=$1 selector=$2 node=$3 pod="" attempt
  for attempt in {1..30}; do
    # Skips pods being deleted: while a pod is replaced, the node briefly has two.
    pod=$(kc -n "$namespace" get pods -l "$selector" --field-selector "spec.nodeName=$node" \
      -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}') ||
      return 1
    pod=$(awk 'NF == 1 { print "pod/" $1; exit }' <<<"$pod")
    [[ -n $pod ]] && break
    ((attempt < 30)) && sleep 2
  done
  [[ -n $pod ]] || {
    echo "$node: no pod matching $selector" >&2
    return 1
  }
  kc -n "$namespace" wait --for=condition=Ready "$pod" --timeout=120s >/dev/null 2>&1 || {
    echo "$node: $pod is not Ready" >&2
    return 1
  }
  echo "$pod"
}

# Runs a command in the pod with the given label on every Ready node, and fails unless
# every output matches the glob pattern.
exec_on_ready_nodes() {
  local namespace=$1 selector=$2 pattern=$3 nodes node pod out bad=0
  shift 3
  nodes=$(ready_nodes) || return 1
  for node in $nodes; do
    pod=$(wait_pod_on_node "$namespace" "$selector" "$node") || {
      bad=1
      continue
    }
    out=$(kc -n "$namespace" exec "$pod" "$@" 2>&1) || true
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ $out == $pattern ]] || {
      echo "$node: $(tail -n1 <<<"$out")"
      bad=1
    }
  done
  return "$bad"
}

lab_reachable() {
  lab_exists || {
    echo "no Lab named '$LAB_NAME'; run 'just up'"
    return 1
  }
  kc get --raw /readyz >/dev/null
}

# The GPU Node may be powered off while Joined; the k3d Nodes must always be Ready.
k3d_nodes_ready() {
  local readiness not_ready
  readiness=$(node_readiness '!k3d-lab/gpu') || return 1
  [[ -n $readiness ]] || {
    echo "no k3d Nodes found"
    return 1
  }
  not_ready=$(awk '$2 != "True" { print $1 }' <<<"$readiness")
  [[ -z $not_ready ]] || {
    echo "not Ready: $(paste -sd' ' <<<"$not_ready")"
    return 1
  }
}

cilium_healthy() {
  exec_on_ready_nodes kube-system k8s-app=cilium OK -c cilium-agent -- cilium-dbg status --brief
}

# The probes the checks below run from. They stay between runs, so this is quick.
probes_deployed() {
  kc apply -f "$LAB_ROOT/scripts/verify/probes.yaml" >/dev/null &&
    kc -n lab-verify rollout status deploy/web --timeout=120s >/dev/null
}

# From a client pod on every Ready node, reach the web Service by its DNS name.
# That needs both DNS (itself a ClusterIP Service) and Cilium's ClusterIP translation.
cluster_ip_services_work() {
  exec_on_ready_nodes lab-verify app=client '*Hostname:*' \
    -- wget -qO- -T 5 http://web.lab-verify.svc.cluster.local/
}

# Names outside the Lab resolve through CoreDNS and Docker's embedded DNS, which needs
# k3d/entrypoint-route-localnet.sh on every k3d Node. ArgoCD reads Git this way.
external_dns_works() {
  local nodes pod out
  nodes=$(ready_nodes) || return 1
  pod=$(wait_pod_on_node lab-verify app=client "$(head -n1 <<<"$nodes")") || return 1
  out=$(kc -n lab-verify exec "$pod" -- nslookup github.com 2>&1) || {
    echo "github.com doesn't resolve from $pod: $(tail -n1 <<<"$out")"
    return 1
  }
}

# The root Application is among them, and it isn't Healthy while an ApplicationSet
# fails to generate its Applications.
applications_synced_and_healthy() {
  local apps not_ok
  apps=$(kc -n argocd get applications \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}') || return 1
  [[ -n $apps ]] || {
    echo "no ArgoCD Applications found"
    return 1
  }
  not_ok=$(awk '$2 != "Synced" || $3 != "Healthy"' <<<"$apps")
  [[ -z $not_ok ]] || {
    echo "$not_ok"
    return 1
  }
}

check "Lab is running" lab_reachable
# Without a Lab, every other check would fail for the same reason.
((fails == 0)) || exit 1
check "Every k3d Node is Ready" k3d_nodes_ready
check "Cilium is healthy on every Ready node" cilium_healthy
check "The verify probes are deployed" probes_deployed
check "ClusterIP Services and DNS work from every Ready node" cluster_ip_services_work
check "Pods resolve names outside the Lab" external_dns_works
check "Every ArgoCD Application is Synced and Healthy" applications_synced_and_healthy

exit $((fails > 0))

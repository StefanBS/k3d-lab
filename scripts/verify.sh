#!/usr/bin/env bash
# Checks how the running Lab behaves, as one named PASS/FAIL/WARN line per check.
# Exits non-zero if any check fails.
#
# Check functions run inside `if`, where `set -e` doesn't apply: every step that can
# fail must return explicitly.
# shellcheck disable=SC2329  # check functions are called indirectly, through check()
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

fails=0

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

ready_nodes() { node_readiness | awk '$2 == "True" { print $1 }'; }

# Waits for the pod with the given label on the given node to be Ready, and prints its name.
wait_pod_on_node() {
  local namespace=$1 selector=$2 node=$3 pod="" attempt
  for attempt in {1..30}; do
    pod=$(kc -n "$namespace" get pods -l "$selector" --field-selector "spec.nodeName=$node" -o name) || return 1
    [[ -n $pod ]] && break
    ((attempt < 30)) && sleep 2
  done
  [[ -n $pod ]] || {
    echo "$node: no pod matching $selector"
    return 1
  }
  kc -n "$namespace" wait --for=condition=Ready "$pod" --timeout=120s >/dev/null || return 1
  echo "$pod"
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
  local nodes node pod status bad=0
  nodes=$(ready_nodes) || return 1
  [[ -n $nodes ]] || {
    echo "no Ready nodes"
    return 1
  }
  for node in $nodes; do
    pod=$(wait_pod_on_node kube-system k8s-app=cilium "$node") || {
      echo "${pod:-$node: cilium-agent pod is not Ready}"
      bad=1
      continue
    }
    status=$(kc -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --brief 2>&1) || true
    [[ $status == OK ]] || {
      echo "$node: $status"
      bad=1
    }
  done
  return "$bad"
}

# From a client pod on every Ready node, reach the web Service by its DNS name.
# That needs both DNS (itself a ClusterIP Service) and Cilium's ClusterIP translation.
cluster_ip_services_work() {
  local nodes node pod out bad=0
  kc apply -f "$LAB_ROOT/scripts/verify/probes.yaml" >/dev/null || return 1
  kc -n lab-verify rollout status deploy/web --timeout=120s >/dev/null 2>&1 || {
    echo "the web probe behind the Service is not available"
    return 1
  }
  nodes=$(ready_nodes) || return 1
  [[ -n $nodes ]] || {
    echo "no Ready nodes"
    return 1
  }
  for node in $nodes; do
    pod=$(wait_pod_on_node lab-verify app=client "$node") || {
      echo "${pod:-$node: client pod is not Ready}"
      bad=1
      continue
    }
    out=$(kc -n lab-verify exec "$pod" -- wget -qO- -T 5 http://web.lab-verify.svc.cluster.local/ 2>&1) || true
    [[ $out == *Hostname:* ]] || {
      echo "from $node: web.lab-verify.svc.cluster.local is unreachable: $(tail -n1 <<<"$out")"
      bad=1
    }
  done
  return "$bad"
}

check "Lab is running" lab_reachable
if ((fails)); then
  exit 1
fi
check "Every k3d Node is Ready" k3d_nodes_ready
check "Cilium is healthy on every Ready node" cilium_healthy
check "ClusterIP Services and DNS work from every Ready node" cluster_ip_services_work

exit $((fails > 0))

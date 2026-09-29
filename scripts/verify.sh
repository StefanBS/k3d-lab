#!/usr/bin/env bash
# Checks how the running Lab behaves, as one named PASS/FAIL/WARN line per check.
# Exits non-zero if any check fails.
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

lab_reachable() {
  lab_exists || {
    echo "no Lab named '$LAB_NAME'; run 'just up'"
    return 1
  }
  kc get --raw /readyz >/dev/null
}

cilium_healthy() {
  local nodes pod status bad=0
  nodes=$(kc get nodes --no-headers | wc -l)
  kc -n kube-system rollout status ds/cilium --timeout=60s >/dev/null
  [[ $(kc -n kube-system get pods -l k8s-app=cilium --no-headers | wc -l) -eq $nodes ]] || {
    echo "expected one Cilium agent per node ($nodes)"
    return 1
  }
  for pod in $(kc -n kube-system get pods -l k8s-app=cilium -o name); do
    status=$(kc -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --brief 2>&1) || true
    [[ $status == OK ]] || {
      echo "$pod: $status"
      bad=1
    }
  done
  return "$bad"
}

deploy_probes() {
  kc apply -f "$LAB_ROOT/scripts/verify/probes.yaml" >/dev/null
  kc -n lab-verify rollout status deploy/web --timeout=120s >/dev/null
  kc -n lab-verify rollout status ds/client --timeout=120s >/dev/null
}

# From a client pod on every Ready node, reach the web Service by its DNS name.
# That needs both DNS (itself a ClusterIP Service) and Cilium's ClusterIP translation.
cluster_ip_services_work() {
  local pod node bad=0
  deploy_probes
  while read -r pod node; do
    kc -n lab-verify exec "$pod" -- wget -qO- -T 5 http://web.lab-verify.svc.cluster.local/ |
      grep -q '^Hostname:' || {
      echo "from $node: web.lab-verify.svc.cluster.local is unreachable"
      bad=1
    }
  done < <(kc -n lab-verify get pods -l app=client \
    -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}')
  return "$bad"
}

check "Lab is running" lab_reachable
if ((fails)); then
  exit 1
fi
check "Cilium is healthy on every node" cilium_healthy
check "ClusterIP Services and DNS work from every node" cluster_ip_services_work

exit $((fails > 0))

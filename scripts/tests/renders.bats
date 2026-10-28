#!/usr/bin/env bats
# What lint judges of the renders (scripts/lib/renders.sh), from hand-written renders and
# a repo of fixtures rather than helm's renders of the Lab's own.

setup() {
  for module in components renders; do
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib/$module.sh"
  done
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  mkdir -p "$LAB_ROOT/gitops"
  printf 'platformNamespaces:\n  - kube-system\n  - monitoring\n' >"$LAB_ROOT/gitops/values.yaml"
}

# component <group>/<name> < <component.yaml>
component() {
  mkdir -p "$LAB_ROOT/$1"
  cat >"$LAB_ROOT/$1/component.yaml"
}

# render <name> < <manifests>: a render, in a file of that name, which it prints.
render() {
  cat >"$BATS_TEST_TMPDIR/$1.yaml"
  echo "$BATS_TEST_TMPDIR/$1.yaml"
}

# A render with an HTTPRoute, beside the Service it routes to.
routed() {
  render "$1" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: ui
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ui
YAML
}

@test "a component in a Wave whose render has an HTTPRoute: names the component" {
  printf 'namespace: kube-system\nwave: controllers\n' | component platform/hubble
  printf 'namespace: kube-system\n' | component platform/gateway
  run wave_routes_problems "platform/gateway=$(routed gateway)" "platform/hubble=$(routed hubble)"
  [[ $status -eq 0 ]]
  [[ $output == "platform/hubble is in a Wave, but renders an HTTPRoute, which can't be Healthy before the Gateway is installed" ]]
}

@test "a component in no Wave with an HTTPRoute, or in a Wave without one: no problems" {
  printf 'namespace: kube-system\n' | component platform/hubble
  printf 'namespace: kube-system\nwave: controllers\n' | component platform/cilium
  run wave_routes_problems "platform/hubble=$(routed hubble)" \
    "platform/cilium=$(printf 'kind: Service\nmetadata:\n  name: hubble-relay\n' | render cilium)"
  [[ $status -eq 0 && -z $output ]]
}

@test "a Platform render that creates or installs into an unlisted namespace, and a listed one no component has: names each" {
  printf 'namespace: kube-system\n' | component platform/cilium
  cilium=$(render cilium <<'YAML'
kind: Namespace
metadata:
  name: cilium-secrets
---
kind: Role
metadata:
  name: tls
  namespace: cilium-secrets
---
kind: DaemonSet
metadata:
  name: cilium
---
kind: Secret
metadata:
  name: ca
  namespace: cert-manager
YAML
  )
  run platform_namespaces_problems "platform/cilium=$cilium"
  [[ $status -eq 0 ]]
  [[ $output == "gitops/values.yaml: platformNamespaces doesn't list cert-manager, which a Platform component's render creates or installs into
gitops/values.yaml: platformNamespaces doesn't list cilium-secrets, which a Platform component's render creates or installs into
gitops/values.yaml: platformNamespaces lists monitoring, which no Platform component creates or installs into" ]]
}

@test "every namespace the Platform renders is listed or a component's own, and each listed one is a component's own or rendered: no problems" {
  printf 'namespace: kube-system\n' | component platform/cilium
  # Its own namespace unlisted is for components_problems to report.
  printf 'namespace: grafana\n' | component platform/grafana
  run platform_namespaces_problems \
    "platform/cilium=$(printf 'kind: DaemonSet\nmetadata:\n  name: cilium\n' | render cilium)" \
    "platform/grafana=$(printf 'kind: Namespace\nmetadata:\n  name: monitoring\n---\nkind: Deployment\nmetadata:\n  name: grafana\n  namespace: grafana\n' | render grafana)"
  [[ $status -eq 0 && -z $output ]]
}

# application <name> <source path>...: an Application's render, with a source per path.
application() {
  local name=$1 path
  shift
  {
    printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: shop\nspec:\n  sources:\n'
    for path; do printf '    - repoURL: https://git.example.com/lab\n      path: %s\n' "$path"; done
  } | render "$name"
}

@test "a Workload's Application without the same-namespace allow, or with it when strict: names the folder" {
  run same_namespace_source_problems workloads/shop "$(application unisolated workloads/shop)" \
    "$(application strict workloads/shop)"
  [[ $status -eq 0 ]]
  [[ $output == "workloads/shop's Application doesn't get the same-namespace allow" ]]
  run same_namespace_source_problems workloads/shop \
    "$(application unisolated workloads/shop platform/workload-network-policy/same-namespace)" \
    "$(application strict workloads/shop platform/workload-network-policy/same-namespace)"
  [[ $status -eq 0 ]]
  [[ $output == "workloads/shop's Application gets the same-namespace allow even when it's isolation: strict" ]]
}

@test "a Workload's Application with the same-namespace allow, and without it when strict: no problems" {
  run same_namespace_source_problems workloads/shop \
    "$(application unisolated workloads/shop platform/workload-network-policy/same-namespace)" \
    "$(application strict workloads/shop)"
  [[ $status -eq 0 && -z $output ]]
}

# applicationset <name> [role]: an ApplicationSet as the gitops chart renders it, its git
# generator selecting by Wave, and with "role", leaving the Demos out too.
applicationset() {
  printf -- '---\napiVersion: argoproj.io/v1alpha1\nkind: ApplicationSet\nmetadata:\n  name: %s\n' "$1"
  printf 'spec:\n  generators:\n    - selector:\n        matchExpressions:\n          - key: wave\n            operator: DoesNotExist\n'
  if [[ ${2:-} == role ]]; then
    printf '          - key: role\n            operator: NotIn\n            values: [demo]\n'
  fi
}

@test "an ApplicationSet besides workloads leaving the Demos out, or one leaving them out with demos: true: says which" {
  run demos_selector_problems \
    "$({ applicationset platform role && applicationset workloads role; } | render without-demos)" \
    "$({ applicationset platform && applicationset workloads; } | render with-demos)"
  [[ $status -eq 0 ]]
  [[ $output == "the workloads ApplicationSet, and only it, should leave the Demos out by default" ]]
  run demos_selector_problems \
    "$({ applicationset platform && applicationset workloads role; } | render without-demos)" \
    "$({ applicationset platform && applicationset workloads role; } | render with-demos)"
  [[ $status -eq 0 ]]
  [[ $output == "an ApplicationSet leaves the Demos out even with demos: true" ]]
  run demos_selector_problems \
    "$({ applicationset platform && applicationset workloads; } | render without-demos)" \
    "$({ applicationset platform && applicationset workloads; } | render with-demos)"
  [[ $status -eq 0 ]]
  [[ $output == "the workloads ApplicationSet, and only it, should leave the Demos out by default" ]]
}

@test "only the workloads ApplicationSet leaving the Demos out, and none with demos: true: no problems" {
  run demos_selector_problems \
    "$({ applicationset platform && applicationset workloads role; } | render without-demos)" \
    "$({ applicationset platform && applicationset workloads; } | render with-demos)"
  [[ $status -eq 0 && -z $output ]]
}

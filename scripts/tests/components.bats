#!/usr/bin/env bats
# The component folders (scripts/lib/components.sh), from a repo of fixtures rather than
# the Lab's own: what each component.yaml says, and what it may say.

setup() {
  # shellcheck source=../lib/components.sh
  source "$BATS_TEST_DIRNAME/../lib/components.sh"
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  mkdir -p "$LAB_ROOT/gitops"
  printf 'platformWaves:\n  - controllers\n  - platform\n' >"$LAB_ROOT/gitops/values.yaml"
}

# component <group>/<name> [<file>...] < <component.yaml>: a component folder, with that
# component.yaml and those files beside it.
component() {
  local dir=$LAB_ROOT/$1 file
  mkdir -p "$dir"
  cat >"$dir/component.yaml"
  shift
  for file; do touch "$dir/$file"; done
}

# A Platform component with a chart, and a Workload without one, as they should be.
chart() { printf 'chart: %s\nrepoURL: https://charts.example.com\nversion: 1.2.3\nnamespace: %s\n' "$1" "$2"; }
kustomized() { printf 'namespace: %s\n' "$1"; }

# expect <want> <got>
expect() {
  [[ $2 == "$1" ]] || {
    echo "want: $1"
    echo "got:  $2"
    return 1
  }
}

@test "the folders, Platform then Workloads, and which are Demos" {
  chart cilium kube-system | component platform/cilium values.yaml
  kustomized comfyui | component workloads/comfyui kustomization.yaml
  { kustomized rollouts-demo && echo 'role: demo'; } | component workloads/rollouts-demo kustomization.yaml
  expect "platform/cilium
workloads/comfyui
workloads/rollouts-demo" "$(component_dirs)"
  expect workloads/rollouts-demo "$(demo_dirs)"
}

@test "a chart's helm arguments, and a folder's namespace" {
  chart cilium kube-system | component platform/cilium values.yaml
  expect "cilium
--repo
https://charts.example.com
--version
1.2.3
--namespace
kube-system
--values
$LAB_ROOT/platform/cilium/values.yaml" "$(component_helm_args platform/cilium)"
  component_has_chart platform/cilium
  kustomized comfyui | component workloads/comfyui kustomization.yaml
  ! component_has_chart workloads/comfyui
  expect comfyui "$(component_namespace workloads/comfyui)"
}

@test "folders as the ApplicationSets expect them: no problems" {
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  { kustomized comfyui && echo 'isolation: strict'; } | component workloads/comfyui kustomization.yaml
  { kustomized rollouts-demo && echo 'role: demo'; } | component workloads/rollouts-demo kustomization.yaml
  expect "" "$(components_problems)"
}

@test "no folders: says so" {
  expect "no component folders found" "$(components_problems)"
}

@test "a name used in both groups: names it" {
  chart grafana grafana | component platform/grafana values.yaml
  kustomized grafana | component workloads/grafana kustomization.yaml
  expect "component names used twice: grafana" "$(components_problems)"
}

@test "a missing field, or the file the component needs: names each" {
  echo 'chart: cilium' | component platform/cilium
  echo '{}' | component workloads/comfyui kustomization.yaml
  expect "platform/cilium/component.yaml: 'namespace' is missing
platform/cilium/component.yaml: 'repoURL' is missing
platform/cilium/component.yaml: 'version' is missing
platform/cilium/values.yaml is missing
workloads/comfyui/component.yaml: 'namespace' is missing" "$(components_problems)"
}

@test "wave: only a Platform component's, and only a listed one" {
  { chart cilium kube-system && echo 'wave: last'; } | component platform/cilium values.yaml
  { kustomized comfyui && echo 'wave: platform'; } | component workloads/comfyui kustomization.yaml
  expect "platform/cilium/component.yaml: 'wave' isn't one of gitops/values.yaml's platformWaves
workloads/comfyui/component.yaml: only a Platform component sets 'wave'" "$(components_problems)"
}

@test "isolation and role: only a Workload's, and only strict and demo" {
  { chart cilium kube-system && echo 'role: demo'; } | component platform/cilium values.yaml
  { kustomized comfyui && echo 'isolation: loose'; } | component workloads/comfyui kustomization.yaml
  { kustomized rollouts-demo && echo 'role: other'; } | component workloads/rollouts-demo kustomization.yaml
  expect "platform/cilium/component.yaml: only a Workload sets 'role'
workloads/comfyui/component.yaml: 'isolation' can only be 'strict'
workloads/rollouts-demo/component.yaml: 'role' can only be 'demo'" "$(components_problems)"
}

#!/usr/bin/env bats
# The component folders (scripts/lib/components.sh), from a repo of fixtures rather than
# the Lab's own: what each component.yaml says, and what it may say.

setup() {
  # shellcheck source=../lib/components.sh
  source "$BATS_TEST_DIRNAME/../lib/components.sh"
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  mkdir -p "$LAB_ROOT/gitops"
  # As the Lab's own lists them: the Features, the Waves, before the Platform's last
  # ApplicationSet, and the Platform's namespaces.
  printf 'features:\n  - observability\n  - gpu\nwithout: []\nplatformWaves:\n  - crds\n  - controllers\nplatformNamespaces:\n  - kube-system\n  - monitoring\n' \
    >"$LAB_ROOT/gitops/values.yaml"
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

# The Platform as gitops/values.yaml lists it: a component in each Wave, and one in none,
# each in a listed namespace.
platform() {
  { chart prometheus-crds monitoring && echo 'wave: crds'; } | component platform/prometheus-crds values.yaml
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  chart grafana monitoring | component platform/grafana values.yaml
}

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

@test "a component's Wave, or nothing when it sets none" {
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  chart grafana monitoring | component platform/grafana values.yaml
  expect controllers "$(component_wave platform/cilium)"
  expect "" "$(component_wave platform/grafana)"
}

@test "a component's Feature, or nothing when it's in none, and a Feature's folders" {
  platform
  { chart loki monitoring && echo 'feature: observability'; } | component platform/loki values.yaml
  { kustomized comfyui && echo 'feature: gpu'; } | component workloads/comfyui kustomization.yaml
  expect observability "$(component_feature platform/loki)"
  expect "" "$(component_feature platform/grafana)"
  expect "platform/loki" "$(feature_dirs observability)"
  expect "workloads/comfyui" "$(feature_dirs gpu)"
}

@test "without_features: the Features named, once each, in the order given" {
  expect "gpu
observability" "$(without_features gpu,observability,gpu)"
  expect observability "$(without_features observability,)"
}

@test "without_features: none, or nothing, leaves every Feature in" {
  run without_features none
  [[ $status -eq 0 && -z $output ]]
  run without_features ''
  [[ $status -eq 0 && -z $output ]]
}

@test "without_features: a name that isn't a Feature fails, naming it and the Features, and prints none of the others" {
  run without_features gpu,observabilty
  [[ $status -eq 1 ]]
  expect "not a Feature: 'observabilty'; the Features are observability gpu, or none for every one" "$output"
  run without_features none,gpu
  [[ $status -eq 1 && $output == "not a Feature: 'none';"* ]]
  run without_features gpu,,observability
  [[ $status -eq 1 && $output == "not a Feature: '';"* ]]
}

@test "demos_lacking: each Demo that needs a Feature left out, with those it lacks" {
  { kustomized rollouts-demo && printf 'role: demo\nneeds: [observability, gpu]\n'; } |
    component workloads/rollouts-demo kustomization.yaml
  { kustomized web-demo && printf 'role: demo\nneeds: [gpu]\n'; } | component workloads/web-demo kustomization.yaml
  { kustomized plain-demo && echo 'role: demo'; } | component workloads/plain-demo kustomization.yaml
  expect "gpu" "$(component_needs workloads/web-demo)"
  expect "" "$(component_needs workloads/plain-demo)"
  expect "rollouts-demo needs observability, gpu
web-demo needs gpu" "$(demos_lacking gpu observability)"
  expect "rollouts-demo needs observability" "$(demos_lacking observability)"
  expect "" "$(demos_lacking)"
}

@test "folders as the ApplicationSets expect them: no problems" {
  platform
  { chart loki monitoring && echo 'feature: observability'; } | component platform/loki values.yaml
  { kustomized comfyui && echo 'feature: gpu'; } | component workloads/comfyui kustomization.yaml
  { kustomized web && echo 'isolation: strict'; } | component workloads/web kustomization.yaml
  { kustomized rollouts-demo && printf 'role: demo\nneeds: [observability]\n'; } |
    component workloads/rollouts-demo kustomization.yaml
  expect "" "$(components_problems)"
}

@test "a feature that gitops/values.yaml doesn't list: names the component" {
  platform
  { chart loki monitoring && echo 'feature: logging'; } | component platform/loki values.yaml
  { kustomized comfyui && echo 'feature: GPU'; } | component workloads/comfyui kustomization.yaml
  expect "platform/loki/component.yaml: 'feature' isn't one of gitops/values.yaml's features
workloads/comfyui/component.yaml: 'feature' isn't one of gitops/values.yaml's features" "$(components_problems)"
}

@test "without naming what features doesn't list, a Feature listed twice, or one named none: names each" {
  platform
  yq -i '.features += ["gpu", "none"] | .without = ["gpu", "tracing"]' "$LAB_ROOT/gitops/values.yaml"
  expect "gitops/values.yaml: features lists gpu twice
gitops/values.yaml: no Feature can be named none
gitops/values.yaml: without names tracing, which isn't one of its features" "$(components_problems)"
}

@test "a Wave whose every component is in a Feature: names the Wave" {
  { chart prometheus-crds monitoring && printf 'wave: crds\nfeature: observability\n'; } |
    component platform/prometheus-crds values.yaml
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  { chart kyverno kube-system && printf 'wave: controllers\nfeature: gpu\n'; } | component platform/kyverno values.yaml
  chart grafana monitoring | component platform/grafana values.yaml
  expect "gitops/values.yaml: every Platform component in the Wave crds is in a Feature, which leaves its ApplicationSet with none in a Lab without them" \
    "$(components_problems)"
}

@test "every Platform component that sets no Wave in a Feature: says the last ApplicationSet gets none" {
  { chart prometheus-crds monitoring && echo 'wave: crds'; } | component platform/prometheus-crds values.yaml
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  { chart grafana monitoring && echo 'feature: observability'; } | component platform/grafana values.yaml
  expect "gitops/values.yaml: every Platform component that sets no Wave is in a Feature, which leaves the Platform's last ApplicationSet with none in a Lab without them" \
    "$(components_problems)"
}

@test "no folders: says so" {
  expect "no component folders found" "$(components_problems)"
}

@test "a name used in both groups: names it" {
  platform
  kustomized grafana | component workloads/grafana kustomization.yaml
  expect "component names used twice: grafana" "$(components_problems)"
}

@test "a missing field, or the file the component needs: names each" {
  platform
  echo 'chart: loki' | component platform/loki
  echo '{}' | component workloads/comfyui kustomization.yaml
  expect "platform/loki/component.yaml: 'namespace' is missing
platform/loki/component.yaml: 'repoURL' is missing
platform/loki/component.yaml: 'version' is missing
platform/loki/values.yaml is missing
workloads/comfyui/component.yaml: 'namespace' is missing" "$(components_problems)"
}

@test "wave: only a Platform component's, and only a listed one" {
  platform
  { chart loki monitoring && echo 'wave: last'; } | component platform/loki values.yaml
  { kustomized comfyui && echo 'wave: controllers'; } | component workloads/comfyui kustomization.yaml
  expect "platform/loki/component.yaml: 'wave' isn't one of gitops/values.yaml's platformWaves
workloads/comfyui/component.yaml: only a Platform component sets 'wave'" "$(components_problems)"
}

@test "isolation and role: only a Workload's, and only strict and demo" {
  platform
  { chart loki monitoring && echo 'role: demo'; } | component platform/loki values.yaml
  { kustomized comfyui && echo 'isolation: loose'; } | component workloads/comfyui kustomization.yaml
  { kustomized rollouts-demo && echo 'role: other'; } | component workloads/rollouts-demo kustomization.yaml
  expect "platform/loki/component.yaml: only a Workload sets 'role'
workloads/comfyui/component.yaml: 'isolation' can only be 'strict'
workloads/rollouts-demo/component.yaml: 'role' can only be 'demo'" "$(components_problems)"
}

@test "needs: only a Demo's, a list, and only of listed Features" {
  platform
  { chart loki monitoring && echo 'needs: [gpu]'; } | component platform/loki values.yaml
  { kustomized comfyui && echo 'needs: [gpu]'; } | component workloads/comfyui kustomization.yaml
  { kustomized web-demo && printf 'role: demo\nneeds: gpu\n'; } | component workloads/web-demo kustomization.yaml
  { kustomized rollouts-demo && printf 'role: demo\nneeds: [gpu, tracing]\n'; } |
    component workloads/rollouts-demo kustomization.yaml
  expect "platform/loki/component.yaml: only a Demo (role: demo) sets 'needs'
workloads/comfyui/component.yaml: only a Demo (role: demo) sets 'needs'
workloads/rollouts-demo/component.yaml: 'needs' names tracing, which isn't one of gitops/values.yaml's features
workloads/web-demo/component.yaml: 'needs' is a list of Features" "$(components_problems)"
}

@test "a listed Wave without a Platform component: names it" {
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  chart grafana monitoring | component platform/grafana values.yaml
  expect "gitops/values.yaml: no Platform component is in the Wave crds" "$(components_problems)"
}

@test "every Platform component in a Wave: says the last ApplicationSet gets none" {
  { chart prometheus-crds monitoring && echo 'wave: crds'; } | component platform/prometheus-crds values.yaml
  { chart cilium kube-system && echo 'wave: controllers'; } | component platform/cilium values.yaml
  expect "gitops/values.yaml: every Platform component sets a Wave, which leaves the Platform's last ApplicationSet with none" \
    "$(components_problems)"
}

@test "a Platform component's namespace that gitops/values.yaml doesn't list: names it" {
  platform
  chart loki loki | component platform/loki values.yaml
  expect "platform/loki/component.yaml: its namespace loki isn't in gitops/values.yaml's platformNamespaces" \
    "$(components_problems)"
}

@test "a Workload in one of the Platform's namespaces: names it" {
  platform
  kustomized monitoring | component workloads/comfyui kustomization.yaml
  expect "workloads/comfyui/component.yaml: its namespace monitoring is one of gitops/values.yaml's platformNamespaces" \
    "$(components_problems)"
}

@test "no Platform component: every Wave, and the Platform's last ApplicationSet, has none" {
  kustomized comfyui | component workloads/comfyui kustomization.yaml
  expect "gitops/values.yaml: no Platform component is in the Wave crds
gitops/values.yaml: no Platform component is in the Wave controllers
gitops/values.yaml: every Platform component sets a Wave, which leaves the Platform's last ApplicationSet with none" \
    "$(components_problems)"
}

@test "a namespace gitops/values.yaml lists twice: names it" {
  platform
  printf '  - monitoring\n' >>"$LAB_ROOT/gitops/values.yaml"
  expect "gitops/values.yaml: platformNamespaces lists monitoring twice" "$(components_problems)"
}

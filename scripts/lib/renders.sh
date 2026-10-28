# What lint judges of the renders: each function reads renders that lint made with helm
# or kustomize, passed as files, and prints one problem per line, or nothing. Sourced by
# lint.sh, and on its own by scripts/tests/, so it sets no shell options and runs nothing
# when sourced. Every path but a render's is under LAB_ROOT.
# shellcheck shell=bash

# wave_routes_problems <component folder>=<its render>...: a component in a Wave renders
# no HTTPRoute. ArgoCD calls one Progressing until the Gateway accepts it, and the Gateway
# is installed after every Wave, since it needs the Waves' cert-manager and Cilium. Its
# Wave would never be Healthy.
wave_routes_problems() {
  local pair dir
  for pair; do
    dir=${pair%%=*}
    [[ -n $(component_wave "$dir") ]] || continue
    if [[ -n $(yq -N 'select(.kind == "HTTPRoute") | .metadata.name' "${pair#*=}") ]]; then
      echo "$dir is in a Wave, but renders an HTTPRoute, which can't be Healthy before the Gateway is installed"
    fi
  done
}

# platform_namespaces_problems <component folder>=<its render>...: given every Platform
# component, the namespaces gitops/values.yaml lists for the workloads project to refuse
# are the Platform's. The gitops chart can't read component.yaml, so it lists them itself.
# components_problems checks each component's own is listed; this checks the rest: each
# other namespace a render creates or installs into, such as Cilium's cilium-secrets, is
# listed, and every listed one is a Platform component's.
platform_namespaces_problems() {
  local pair namespace listed own="" rendered=""
  listed=$(yq '.platformNamespaces[]' "$LAB_ROOT/gitops/values.yaml")
  for pair; do
    own+=$(component_namespace "${pair%%=*}")$'\n'
    rendered+=$(_rendered_namespaces "${pair#*=}")$'\n'
  done
  while read -r namespace; do
    grep -qxF -- "$namespace" <<<"$own$listed" ||
      echo "gitops/values.yaml: platformNamespaces doesn't list $namespace, which a Platform component's render creates or installs into"
  done < <(grep . <<<"$rendered" | sort -u)
  for namespace in $listed; do
    grep -qxF -- "$namespace" <<<"$own$rendered" ||
      echo "gitops/values.yaml: platformNamespaces lists $namespace, which no Platform component creates or installs into"
  done
}

# _rendered_namespaces <render>: the namespaces a render creates, or names for a resource,
# one per line. One that names none is installed into its component's own.
_rendered_namespaces() {
  yq -N 'select(.kind == "Namespace") | .metadata.name, (select(.kind != "Namespace") | .metadata.namespace // "")' \
    "$1" | grep . || true
}

# same_namespace_source_problems <Workload folder> <its Application's render> <its render
# as if isolation: strict>: a Workload's Application gets the baseline's same-namespace
# allow as a source, unless it's `isolation: strict`.
same_namespace_source_problems() {
  local source='.spec.sources[] | select(.path == "platform/workload-network-policy/same-namespace")'
  [[ -n $(yq "$source" "$2") ]] || echo "$1's Application doesn't get the same-namespace allow"
  [[ -z $(yq "$source" "$3") ]] || echo "$1's Application gets the same-namespace allow even when it's isolation: strict"
}

# demos_selector_problems <the gitops render> <its render with demos=true>: the workloads
# ApplicationSet leaves the Demos out, with a selector on its generator, unless the Lab
# has its Demos. The Platform's select only by Wave.
demos_selector_problems() {
  local selectors='[select(.kind == "ApplicationSet") | select(.spec.generators[0].selector.matchExpressions[]? | .key == "role") | .metadata.name] | unique | join(" ")'
  [[ $(yq ea "$selectors" "$1") == workloads ]] ||
    echo "the workloads ApplicationSet, and only it, should leave the Demos out by default"
  [[ -z $(yq ea "$selectors" "$2") ]] || echo "an ApplicationSet leaves the Demos out even with demos: true"
}

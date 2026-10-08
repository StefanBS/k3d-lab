#!/usr/bin/env bash
# Static checks that need no Lab. CI runs this on every PR.
# Every check runs, even after one fails; the script fails if any did.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit

# The Kubernetes version the Lab runs, from its k3s image: v1.36.4-k3s1 is 1.36.4.
k8s_version=$(yq '.image' k3d/cluster.yaml | sed -n 's/.*:v\([0-9.]*\)-k3s.*/\1/p')
[[ -n $k8s_version ]] || die "can't read the Kubernetes version from k3d/cluster.yaml's image"

# Where each render goes. kubeconform only reads files named .yaml or .json.
manifests=$(mktemp --suffix=.yaml)
# A chart with a template per group: a component's Application, as its ApplicationSet
# generates it (render_application).
application_chart=$(mktemp -d)
# The enforced admission policies, which reject an object rather than only report it,
# so a component that breaks one fails its sync (read_policies).
enforced_policies=$(mktemp --suffix=.yaml)
# Every component's render, as Kyverno admits it (add_admitted).
admitted=$(mktemp --suffix=.yaml)
trap 'rm -rf "$manifests" "$application_chart" "$enforced_policies" "$admitted"' EXIT

# The ApplicationSets template these fields into each component's Application.
lint_component_folder() {
  local dir=$1 key keys=(namespace) file=kustomization.yaml
  if component_has_chart "$dir"; then
    keys+=(repoURL version)
    file=values.yaml
  fi
  for key in "${keys[@]}"; do
    # -e: fails when the key is missing or null.
    yq -e ".$key" "$dir/component.yaml" >/dev/null 2>&1 || fail "$dir/component.yaml: '$key' is missing"
  done
  [[ -f $dir/$file ]] || fail "$dir/$file is missing"
  # Optional, and only a Workload's: the workloads ApplicationSet labels its namespace.
  if [[ $(yq 'has("isolation")' "$dir/component.yaml") == true ]]; then
    if [[ $dir != workloads/* ]]; then
      fail "$dir/component.yaml: only a Workload sets 'isolation'"
    elif [[ $(yq '.isolation' "$dir/component.yaml") != strict ]]; then
      fail "$dir/component.yaml: 'isolation' can only be 'strict'"
    fi
  fi
}

# The gitops chart can't read component.yaml, so it lists the Platform's namespaces
# itself, for the workloads project to refuse. Checks it lists exactly those: each
# Platform component's own, and any other its render creates or installs into, such as
# Cilium's cilium-secrets (rendered_namespaces).
lint_platform_namespaces() {
  local dir listed actual
  listed=$(yq '.platformNamespaces[]' gitops/values.yaml | sort)
  for dir in "${components[@]}"; do
    if [[ $dir == workloads/* ]] && grep -qxF "$(component_namespace "$dir")" <<<"$listed"; then
      fail "$dir's namespace is one of the Platform's (gitops/values.yaml)"
    fi
  done
  actual=$({
    for dir in "${components[@]}"; do
      if [[ $dir == platform/* ]]; then component_namespace "$dir"; fi
    done
    printf '%s' "$platform_rendered_namespaces"
  } | grep . | sort -u)
  if [[ $listed == "$actual" ]]; then
    ok "gitops/values.yaml lists the Platform's namespaces"
  else
    fail "gitops/values.yaml's platformNamespaces aren't the Platform's namespaces:"$'\n'"$(diff <(echo "$listed") <(echo "$actual"))"
  fi
}

# Renders a component into $manifests the way ArgoCD does: its pinned chart and values,
# or its kustomization.
render_component() {
  local args
  if ! component_has_chart "$1"; then
    kubectl kustomize "$1" >"$manifests"
    return
  fi
  mapfile -t args < <(component_helm_args "$1")
  helm template "${1##*/}" "${args[@]}" --include-crds --kube-version "$k8s_version" >"$manifests"
}

# The namespaces the render in $manifests creates, or names for a resource. One that
# names none is installed into its component's namespace.
rendered_namespaces() {
  yq -N 'select(.kind == "Namespace") | .metadata.name, (select(.kind != "Namespace") | .metadata.namespace // "")' \
    "$manifests" | grep . || true
}

# Renders a component's Application into $manifests the way its ApplicationSet does:
# its template, then its templatePatch over it, each through Go templates with the
# component.yaml's keys as `.`. Helm runs the templates, with the same Sprig functions
# as ArgoCD. The patch is merged plainly, map into map, which is all it relies on.
# Helm renders a key that component.yaml lacks as empty, where ArgoCD's missingkey=error
# fails, so an optional key read without hasKey isn't caught here.
# Usage: render_application <component folder> [<yq expression>]
# The expression, if given, changes component.yaml's keys first.
render_application() {
  # The chart's values: component.yaml's keys, and what the git generator adds to them.
  P=$1 B=${1##*/} yq "${2:-.} | . + {\"path\": {\"path\": strenv(P), \"basename\": strenv(B)}}" \
    "$1/component.yaml" >"$application_chart/values.yaml"
  # shellcheck disable=SC2016 # $doc is yq's, not the shell's.
  helm template application "$application_chart" --show-only "templates/${1%%/*}.yaml" |
    yq ea '. as $doc ireduce ({}; . * $doc)' >"$manifests"
}

# A Workload's Application gets the baseline's same-namespace allow as a source, unless
# it's `isolation: strict`. No Workload is yet, so one is rendered as if it were.
lint_same_namespace_source() {
  local dir=$1 source='.spec.sources[] | select(.path == "platform/workload-network-policy/same-namespace")'
  render_application "$dir"
  if [[ -z $(yq "$source" "$manifests") ]]; then
    fail "$dir's Application doesn't get the same-namespace allow"
    return
  fi
  render_application "$dir" '.isolation = "strict"'
  if [[ -n $(yq "$source" "$manifests") ]]; then
    fail "$dir's Application gets the same-namespace allow even when it's isolation: strict"
    return
  fi
  ok "a Workload's Application gets the same-namespace allow, unless it's isolation: strict"
}

# The chart render_application renders, written once: the ApplicationSets don't change
# between components.
write_application_chart() {
  local group appsets appset
  printf 'apiVersion: v2\nname: application\nversion: 0.1.0\n' >"$application_chart/Chart.yaml"
  mkdir "$application_chart/templates"
  appsets=$(helm template gitops gitops --show-only templates/applicationsets.yaml)
  for group in $(yq -N '.metadata.name' <<<"$appsets"); do
    appset=$(GROUP=$group yq 'select(.metadata.name == strenv(GROUP)) | .spec' <<<"$appsets")
    {
      echo '{{- with .Values }}'
      echo 'apiVersion: argoproj.io/v1alpha1'
      echo 'kind: Application'
      yq '.template' <<<"$appset"
      echo '---'
      yq '.templatePatch' <<<"$appset"
      echo '{{- end }}'
    } >"$application_chart/templates/$group.yaml"
  done
}

# Renders what the root Application syncs into $manifests.
render_gitops() {
  helm template gitops gitops --kube-version "$k8s_version" >"$manifests"
}

# The probes that verify's checks deploy are plain manifests: nothing to render.
render_probes() {
  local file
  for file in verify/lib/{probes,gpu-probes,workload-probes,baseline-workload,baseline-exposed,baseline-apiserver-allow}.yaml; do
    cat "$file"
    echo ---
  done >"$manifests"
}

# The baseline's same-namespace allow, which the workloads ApplicationSet adds to each
# Workload's Application as a plain folder: nothing to render either.
render_same_namespace_allow() {
  cat platform/workload-network-policy/same-namespace/*.yaml >"$manifests"
}

# Schemas are cached between runs: the CRDs catalog is pinned, so they never change
# under the same URL.
kubeconform_cache=${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform
mkdir -p "$kubeconform_cache"
kubeconform_args=(
  -strict -summary -cache "$kubeconform_cache"
  -kubernetes-version "${k8s_version%.*}.0"
  -schema-location default
  # CRD schemas (ArgoCD, Cilium, cert-manager, ESO, Gateway API, Rollouts...), pinned to
  # a commit of the CRDs catalog so an upstream change can't break lint on its own.
  # Bump it when a component's CRDs need newer schemas.
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/d373c2da9702bc9509a004db83e57263fe3bdfc1/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  # No schema is published for CustomResourceDefinitions themselves.
  -skip CustomResourceDefinition
)

# Renders with a render_* function and its arguments, then validates what it rendered.
lint_rendering() {
  local name=$1 out
  shift
  if ! out=$("$@" 2>&1); then
    fail "$name doesn't render: $out"
  elif ! out=$(kubeconform "${kubeconform_args[@]}" "$manifests" 2>&1); then
    fail "$name doesn't validate:"$'\n'"$out"
  elif [[ $out == *" 0 resource found"* ]]; then
    fail "$name renders nothing"
  else
    ok "$name renders and validates ($(sed -n 's/^Summary: //p' <<<"$out"))"
  fi
}

# The admission policies, and their fixtures: good and bad objects, each with the result
# it should get, in a folder per policy.
policies=platform/kyverno-policies
policy_tests=$policies/tests

# Reads the admission policies as ArgoCD applies them: their names into $policy_names,
# and the enforced ones into $enforced_policies.
read_policies() {
  render_component "$policies"
  policy_names=$(yq -N 'select(.kind == "ValidatingPolicy") | .metadata.name' "$manifests")
  yq 'select(.spec.validationActions | contains(["Deny"]))' "$manifests" >"$enforced_policies"
  # Without one, lint_admission would pass every component.
  [[ -s $enforced_policies ]] || fail "no admission policy is enforced (validationActions: [Deny])"
}

# Each policy's fixtures get the results its kyverno-test.yaml expects.
lint_policy_fixtures() {
  local name test fixtures fixture listed found status=0 out results wrong
  for name in $policy_names; do
    test=$policy_tests/$name/kyverno-test.yaml
    if [[ ! -f $test ]]; then
      fail "the policy $name has no fixtures in $policy_tests/$name/"
      continue
    fi
    mapfile -t fixtures < <(yq ".resources[] | \"${test%/*}/\" + ." "$test")
    for fixture in "${fixtures[@]}"; do
      if [[ ! -f $fixture ]]; then
        fail "$test names $(realpath -m --relative-to=. "$fixture"), which doesn't exist"
        continue 2
      fi
    done
    # kyverno test ignores a fixture without an expected result. Each folder tests one
    # policy, so each fixture is listed once.
    listed=$(yq '[.results[].resources[]] | length' "$test")
    found=$(yq ea '[select(.kind != null)] | length' "${fixtures[@]}")
    [[ $listed == "$found" ]] || fail "$test gives $listed of its $found fixtures an expected result"
  done
  out=$(kyverno test "$policy_tests" --require-tests --detailed-results -o json 2>&1) || status=$?
  # A result per fixture: Pass and Ok when it gets the one expected. kyverno test also
  # passes a fixture its policy doesn't match, whatever result it expects: Excluded.
  results=$(sed -n '/^\[/,/^\]/p' <<<"$out" | yq -p json -o tsv '.[] | [.RESULT, .REASON, .RESOURCE]') || status=$?
  wrong=$(grep -Pv '^Pass\tOk\t' <<<"$results" || true)
  if [[ -n $wrong ]]; then
    fail "fixtures that don't get their expected result, or that their policy doesn't match:"$'\n'"$wrong"
  elif ((status != 0)) || [[ -z $results ]]; then
    fail "kyverno test failed:"$'\n'"$out"
  else
    ok "the admission policies' fixtures get their expected results ($(wc -l <<<"$results"))"
  fi
}

# Adds the component rendered in $manifests to $admitted, as admitted: each object
# without a namespace gets its component's, as ArgoCD installs it there.
add_admitted() {
  echo --- >>"$admitted"
  NS=$(component_namespace "$1") yq 'select(.kind != null) | .metadata.namespace = (.metadata.namespace // strenv(NS)) | ... comments = ""' "$manifests" >>"$admitted"
}

# Every component passes the enforced policies, in one kyverno apply: a process per
# component costs half a second each.
lint_admission() {
  local out
  if out=$(kyverno apply "$enforced_policies" --resource "$admitted" --remove-color 2>&1); then
    ok "every component passes the enforced policies (${#components[@]})"
  else
    fail "a component breaks an enforced policy:"$'\n'"$out"
  fi
}

log "Shell scripts"
if git ls-files -z --cached --others --exclude-standard '*.sh' | xargs -0 shellcheck --external-sources; then
  ok "shellcheck finds nothing"
else
  fail "shellcheck found problems (above)"
fi

# The scripts' logic that needs no Lab, such as the GPU Node's state.
log "Script tests"
if bats scripts/tests; then
  ok "bats passes"
else
  fail "bats found failures (above)"
fi

log "Recipes"
# `just --fmt` reads only the file it's given, never the modules that file names.
for file in Justfile just/*.just; do
  if just --fmt --check --justfile "$file"; then
    ok "$file is formatted"
  else
    fail "$file isn't formatted; run 'just --fmt --justfile $file'"
  fi
done

log "Admission policies"
read_policies
lint_policy_fixtures

log "Components"
mapfile -t components < <(component_dirs)
((${#components[@]})) || fail "no component folders found"
# Each folder's name is its Application's name, and those share one namespace.
duplicates=$(printf '%s\n' "${components[@]##*/}" | sort | uniq -d)
[[ -z $duplicates ]] || fail "component names used twice: $(paste -sd' ' <<<"$duplicates")"
write_application_chart
# What the Platform's renders create or install into, for lint_platform_namespaces.
platform_rendered_namespaces=
for dir in "${components[@]}"; do
  lint_component_folder "$dir"
  lint_rendering "$dir" render_component "$dir"
  if [[ $dir == platform/* ]]; then
    platform_rendered_namespaces+=$(rendered_namespaces)$'\n'
  fi
  # A render that failed left $manifests empty.
  add_admitted "$dir"
  lint_rendering "$dir's Application" render_application "$dir"
done
lint_admission
lint_platform_namespaces
lint_rendering "the same-namespace allow" render_same_namespace_allow
lint_same_namespace_source workloads/rollouts-demo
lint_rendering gitops render_gitops

# Every fact the scripts read from the Platform's values, so a renamed value fails
# here rather than in the middle of `just up`.
log "Platform facts"
unresolved=0
for name in $(printf '%s\n' "${!PLATFORM_FACTS[@]}" | sort); do
  if ! value=$(platform_fact "$name" 2>&1); then
    fail "${value#error: }"
    unresolved=$((unresolved + 1))
  elif [[ -n ${PLATFORM_PINNED_FACTS[$name]:-} ]]; then
    constant=${PLATFORM_PINNED_FACTS[$name]}
    if [[ $value == "${!constant}" ]]; then
      ok "Platform fact '$name' is $constant (${!constant})"
    else
      fail "Platform fact '$name' is '$value', not $constant (${!constant})"
    fi
  fi
done
((unresolved > 0)) || ok "every Platform fact resolves (${#PLATFORM_FACTS[@]})"

# Chainsaw only checks each file against its schema. The step templates have none, so
# a broken one shows up when `just verify` loads the checks that use it.
log "Verify checks"
# lint_chainsaw <test|configuration> <file>
lint_chainsaw() {
  local out
  if out=$(chainsaw lint "$1" -f "$2" 2>&1); then
    ok "$2 is a valid Chainsaw $1"
  else
    fail "$2 isn't a valid Chainsaw $1:"$'\n'"$out"
  fi
}
lint_chainsaw configuration verify/.chainsaw.yaml
for file in verify/*/chainsaw-test.yaml; do
  lint_chainsaw test "$file"
done
lint_rendering "verify's probes" render_probes

((fails == 0)) || die "lint found $fails problem(s)"
log "Lint passed"

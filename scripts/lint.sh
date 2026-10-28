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

# report_problems <OK line> <command>...: a FAIL for each problem the command prints, one
# per line, or the OK line when it prints none.
report_problems() {
  local passed=$1 problems problem
  shift
  problems=$("$@")
  if [[ -z $problems ]]; then
    ok "$passed"
    return
  fi
  while IFS= read -r problem; do fail "$problem"; done <<<"$problems"
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

# Each Wave gitops/values.yaml lists has a Platform component: the root Application's sync
# would wait forever for an ApplicationSet with none to be Healthy
# (platform/argocd/values.yaml). So would it for the Platform's last one, which gets the
# components that set no Wave.
lint_platform_waves() {
  local wave waves empty=0
  # A component that sets no Wave prints an empty line.
  waves=$(for dir in "${components[@]}"; do
    if [[ $dir == platform/* ]]; then yq '.wave // ""' "$dir/component.yaml"; fi
  done)
  for wave in $(yq '.platformWaves[]' gitops/values.yaml); do
    grep -qxF -- "$wave" <<<"$waves" && continue
    fail "no Platform component is in the Wave $wave (gitops/values.yaml)"
    empty=$((empty + 1))
  done
  if ! grep -qx '' <<<"$waves"; then
    fail "every Platform component sets a Wave, which leaves the Platform's last ApplicationSet with none"
    empty=$((empty + 1))
  fi
  ((empty > 0)) || ok "every Wave has a Platform component"
}

# A component in a Wave renders no HTTPRoute: ArgoCD calls one Progressing until the
# Gateway accepts it, and the Gateway is installed after every Wave, since it needs the
# Waves' cert-manager and Cilium. Its Wave would never be Healthy. Reads the component
# that render_component rendered last.
lint_wave_routes() {
  local dir=$1
  [[ $(yq 'has("wave")' "$dir/component.yaml") == true ]] || return 0
  if [[ -n $(yq -N 'select(.kind == "HTTPRoute") | .metadata.name' "$manifests") ]]; then
    fail "$dir is in a Wave, but renders an HTTPRoute, which can't be Healthy before the Gateway is installed"
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
# between components, and a group's waves share one template.
write_application_chart() {
  local group appsets appset
  printf 'apiVersion: v2\nname: application\nversion: 0.1.0\n' >"$application_chart/Chart.yaml"
  mkdir "$application_chart/templates"
  appsets=$(helm template gitops gitops --show-only templates/applicationsets.yaml)
  for group in $(yq -N '.spec.template.metadata.labels["k3d-lab/group"]' <<<"$appsets" | sort -u); do
    appset=$(GROUP=$group yq 'select(.spec.template.metadata.labels["k3d-lab/group"] == strenv(GROUP)) | .spec' <<<"$appsets" |
      yq -N 'select(document_index == 0)')
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

# Renders what the root Application syncs into $manifests, given any values to set.
render_gitops() {
  helm template gitops gitops --kube-version "$k8s_version" "$@" >"$manifests"
}

# The workloads ApplicationSet leaves the Demos out, with a selector on its generator,
# unless the Lab has its Demos. The Platform's select only by Wave.
lint_demos_selector() {
  local selectors='[select(.kind == "ApplicationSet") | select(.spec.generators[0].selector.matchExpressions[]? | .key == "role") | .metadata.name] | unique | join(" ")'
  render_gitops
  if [[ $(yq ea "$selectors" "$manifests") != workloads ]]; then
    fail "the workloads ApplicationSet, and only it, should leave the Demos out by default"
    return
  fi
  render_gitops --set demos=true
  if [[ -n $(yq ea "$selectors" "$manifests") ]]; then
    fail "an ApplicationSet leaves the Demos out even with demos: true"
    return
  fi
  ok "the workloads ApplicationSet leaves the Demos out, unless the Lab has its Demos"
}

# A check that names a Demo's namespace, itself or in a script it runs from verify/lib/,
# fails on a Lab without its Demos, unless it carries the Demo label, which verify
# deselects there.
lint_demo_checks() {
  local dir namespace test files unlabelled=0
  for dir in $(demo_dirs); do
    namespace=$(component_namespace "$dir")
    for test in verify/*/chainsaw-test.yaml; do
      mapfile -t files < <(grep -o '\.\./lib/[A-Za-z0-9._-]*' "$test" | sort -u | sed "s|^\.\./|verify/|")
      grep -qw -- "$namespace" "$test" "${files[@]}" || continue
      [[ $(KEY=$DEMO_LABEL_KEY yq '.metadata.labels | has(strenv(KEY))' "$test") == true ]] && continue
      fail "$test names the Demo's namespace $namespace, but isn't labelled $DEMO_LABEL_KEY"
      unlabelled=$((unlabelled + 1))
    done
  done
  ((unlabelled > 0)) || ok "every check that names a Demo's namespace is labelled $DEMO_LABEL_KEY"
}

# The probes that verify's checks deploy are plain manifests: nothing to render. The
# other YAML in verify/lib/ is Chainsaw's own, which `chainsaw lint` checks.
render_probes() { yq 'select(.kind != "StepTemplate")' verify/lib/*.yaml >"$manifests"; }

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
if git ls-files -z --cached --others --exclude-standard '*.sh' | xargs -0 -n 1 -P "$(nproc)" shellcheck --external-sources; then
  ok "shellcheck finds nothing"
else
  fail "shellcheck found problems (above)"
fi

# A script's folder says how it runs (CODING_STANDARDS.md): run, sourced after lib.sh, or
# sent to another machine.
lint_script_folders() {
  local file before=$fails
  while IFS= read -r -d '' file; do
    case $file in
      scripts/lib.sh)
        # Only the bootstrap: what a function does belongs to the module of what it reads.
        if grep -qE '^\s*(function\s+\w+|\w+\s*\(\))' "$file"; then fail "$file is only the bootstrap, so it defines no functions"; fi
        ;;
      scripts/lib/*.sh)
        [[ ! -x $file ]] || fail "$file is sourced, so it isn't executable"
        if grep -qE '^\s*set -' "$file"; then fail "$file is sourced, so it sets no shell options"; fi
        ;;
      scripts/remote/*.sh)
        if grep -qE '^\s*(source|\.)\s' "$file"; then fail "$file runs on another machine, so it sources nothing"; fi
        ;;
      scripts/*/*) fail "$file isn't in scripts/, scripts/lib/ or scripts/remote/" ;;
      *) [[ -x $file ]] || fail "$file is run, so it's executable" ;;
    esac
  done < <(git ls-files -z --cached --others --exclude-standard 'scripts/*.sh' ':!scripts/tests/*')
  ((fails > before)) || ok "every script is in the folder for how it runs"
}
lint_script_folders

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
# `just <module>` runs the module's first recipe, so each module starts with a private
# one that only lists the others: `just gpu` mustn't start the GPU wizard.
if ! modules=$(just --dump --dump-format json | jq -re '.modules | to_entries[] | [.key, .value.first // "nothing", .value.source] | @tsv'); then
  fail "can't read the modules' first recipes from 'just --dump'"
fi
while IFS=$'\t' read -r module first source; do
  if [[ $first == _default ]]; then
    ok "just $module lists its recipes"
  else
    fail "just $module runs '$first'; start $(realpath --relative-to=. "$source") with the _default recipe"
  fi
done <<<"$modules"

log "Admission policies"
read_policies
lint_policy_fixtures

log "Components"
report_problems "every component folder is what the ApplicationSets expect" components_problems
mapfile -t components < <(component_dirs)
write_application_chart
# What the Platform's renders create or install into, for lint_platform_namespaces.
platform_rendered_namespaces=
for dir in "${components[@]}"; do
  lint_rendering "$dir" render_component "$dir"
  if [[ $dir == platform/* ]]; then
    platform_rendered_namespaces+=$(rendered_namespaces)$'\n'
    lint_wave_routes "$dir"
  fi
  # A render that failed left $manifests empty.
  add_admitted "$dir"
  lint_rendering "$dir's Application" render_application "$dir"
done
lint_admission
lint_platform_namespaces
lint_platform_waves
lint_rendering "the same-namespace allow" render_same_namespace_allow
lint_same_namespace_source workloads/rollouts-demo
lint_rendering gitops render_gitops
lint_rendering "gitops with the Demos" render_gitops --set demos=true
lint_demos_selector

# Every fact the scripts read from the Platform's values, so a renamed value fails
# here rather than in the middle of `just up`.
log "Platform facts"
report_problems "every Platform fact resolves, and the pinned ones match their constants (${#PLATFORM_FACTS[@]})" \
  platform_facts_problems

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
lint_demo_checks

((fails == 0)) || die "lint found $fails problem(s)"
log "Lint passed"

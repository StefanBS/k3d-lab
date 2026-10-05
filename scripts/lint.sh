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
# A chart whose one template is a component's Application, as its ApplicationSet
# generates it (render_application).
application_chart=$(mktemp -d)
trap 'rm -rf "$manifests" "$application_chart"' EXIT

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
# itself, for the workloads project to refuse. Checks it lists exactly those.
lint_platform_namespaces() {
  local dir listed actual=() actual_sorted
  listed=$(yq '.platformNamespaces[]' gitops/values.yaml | sort)
  for dir in "${components[@]}"; do
    case $dir in
      platform/*) actual+=("$(component_namespace "$dir")") ;;
      workloads/*)
        if grep -qxF "$(component_namespace "$dir")" <<<"$listed"; then
          fail "$dir's namespace is one of the Platform's (gitops/values.yaml)"
        fi
        ;;
    esac
  done
  actual_sorted=$(printf '%s\n' "${actual[@]}" | sort -u)
  if [[ $listed == "$actual_sorted" ]]; then
    ok "gitops/values.yaml lists the Platform's namespaces"
  else
    fail "gitops/values.yaml's platformNamespaces aren't the Platform's namespaces:"$'\n'"$(diff <(echo "$listed") <(echo "$actual_sorted"))"
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

# Renders a component's Application into $manifests the way its ApplicationSet does:
# its template, then its templatePatch over it, each through Go templates with the
# component.yaml's keys as `.`. Helm runs the templates, with the same Sprig functions
# as ArgoCD. The patch is merged plainly, map into map, which is all it relies on.
render_application() {
  local appset
  appset=$(helm template gitops gitops --show-only templates/applicationsets.yaml |
    GROUP=${1%%/*} yq 'select(.metadata.name == strenv(GROUP)) | .spec')
  printf 'apiVersion: v2\nname: application\nversion: 0.1.0\n' >"$application_chart/Chart.yaml"
  mkdir -p "$application_chart/templates"
  {
    echo '{{- with .Values }}'
    echo 'apiVersion: argoproj.io/v1alpha1'
    echo 'kind: Application'
    yq '.template' <<<"$appset"
    echo '---'
    yq '.templatePatch' <<<"$appset"
    echo '{{- end }}'
  } >"$application_chart/templates/application.yaml"
  # What the git generator adds to component.yaml's keys.
  # shellcheck disable=SC2016 # $doc is yq's, not the shell's.
  P=$1 B=${1##*/} yq '. + {"path": {"path": strenv(P), "basename": strenv(B)}}' "$1/component.yaml" |
    helm template application "$application_chart" --values - |
    yq ea '. as $doc ireduce ({}; . * $doc)' >"$manifests"
}

# Renders what the root Application syncs into $manifests.
render_gitops() {
  helm template gitops gitops --kube-version "$k8s_version" >"$manifests"
}

# The probes that verify's checks deploy are plain manifests: nothing to render.
render_probes() {
  cat verify/lib/probes.yaml <(echo ---) verify/lib/gpu-probes.yaml \
    <(echo ---) verify/lib/workload-probes.yaml >"$manifests"
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

log "Components"
mapfile -t components < <(component_dirs)
((${#components[@]})) || fail "no component folders found"
# Each folder's name is its Application's name, and those share one namespace.
duplicates=$(printf '%s\n' "${components[@]##*/}" | sort | uniq -d)
[[ -z $duplicates ]] || fail "component names used twice: $(paste -sd' ' <<<"$duplicates")"
for dir in "${components[@]}"; do
  lint_component_folder "$dir"
  lint_rendering "$dir" render_component "$dir"
  lint_rendering "$dir's Application" render_application "$dir"
done
lint_platform_namespaces
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

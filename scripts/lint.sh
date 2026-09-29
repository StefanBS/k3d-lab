#!/usr/bin/env bash
# Static checks that need no Lab. CI runs this on every PR.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit

fails=0
fail() {
  printf 'FAIL  %s\n' "$1" >&2
  fails=$((fails + 1))
}

# Render and validate for the Kubernetes version the Lab runs.
k8s_version=$(yaml_get k3d/cluster.yaml image | sed -n 's/.*:v\([0-9.]*\)-k3s.*/\1/p')
[[ -n $k8s_version ]] || die "can't read the Kubernetes version from k3d/cluster.yaml's image"
# CRD schemas (ArgoCD, Cilium, cert-manager, ESO, Gateway API, Rollouts...) come from
# the CRDs catalog; everything else from Kubernetes' own schemas.
kubeconform_args=(
  -strict -summary
  # No schema is published for CustomResourceDefinitions themselves.
  -skip CustomResourceDefinition
  -kubernetes-version "${k8s_version%.*}.0"
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

log "shellcheck"
git ls-files -z --cached --others --exclude-standard '*.sh' | xargs -0 shellcheck --external-sources

log "just --fmt --check"
just --fmt --check

# The ApplicationSets template each component's fields, and RollingSync only syncs
# the waves it has a step for (0-9, in gitops/templates/applicationsets.yaml).
log "Component folders"
mapfile -t components < <(component_dirs)
((${#components[@]})) || fail "no component folders found"
for dir in "${components[@]}"; do
  for key in chart repoURL version namespace wave; do
    [[ -n $(yaml_get "$dir/component.yaml" "$key") ]] || fail "$dir/component.yaml: '$key' is missing"
  done
  wave=$(yaml_get "$dir/component.yaml" wave)
  [[ -z $wave || $wave =~ ^[0-9]$ ]] || fail "$dir/component.yaml: wave must be 0 to 9"
  [[ -f $dir/values.yaml ]] || fail "$dir/values.yaml is missing"
done
# Each folder's name is its Application's name, and those share one namespace.
duplicates=$(printf '%s\n' "${components[@]##*/}" | sort | uniq -d)
[[ -z $duplicates ]] || fail "component names used twice: $(paste -sd' ' <<<"$duplicates")"

# Renders with the pinned chart and values, then validates the output.
validate() {
  local name=$1 out
  shift
  if ! out=$("$@" 2>&1 >"$rendered"); then
    fail "$name doesn't render: $out"
  elif ! out=$(kubeconform "${kubeconform_args[@]}" "$rendered" 2>&1); then
    fail "$name doesn't validate:
$out"
  elif [[ $out == *" 0 resource found"* ]]; then
    fail "$name renders nothing"
  else
    printf 'OK    %s: %s\n' "$name" "$(tail -n1 <<<"$out")"
  fi
}
# kubeconform only reads files named .yaml or .json.
rendered=$(mktemp --suffix=.yaml)
trap 'rm -f "$rendered"' EXIT

log "Rendering and validating every component"
for dir in "${components[@]}"; do
  mapfile -t helm_args < <(component_helm_args "$dir")
  validate "$dir" helm template "${dir##*/}" "${helm_args[@]}" --include-crds --kube-version "$k8s_version"
done
validate gitops helm template gitops gitops --kube-version "$k8s_version"

((fails == 0)) || die "lint found $fails problem(s)"
log "Lint passed"

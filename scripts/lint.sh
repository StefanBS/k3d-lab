#!/usr/bin/env bash
# Static checks that need no Lab. CI runs this on every PR.
# Every check runs, even after one fails; the script fails if any did.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit

fails=0
ok() { printf 'OK    %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

# The Kubernetes version the Lab runs, from its k3s image: v1.36.4-k3s1 is 1.36.4.
k8s_version=$(yaml_get k3d/cluster.yaml image | sed -n 's/.*:v\([0-9.]*\)-k3s.*/\1/p')
[[ -n $k8s_version ]] || die "can't read the Kubernetes version from k3d/cluster.yaml's image"

# Where each render goes. kubeconform only reads files named .yaml or .json.
manifests=$(mktemp --suffix=.yaml)
trap 'rm -f "$manifests"' EXIT

# The ApplicationSets template these fields into each component's Application.
lint_component_folder() {
  local dir=$1 key
  for key in chart repoURL version namespace; do
    [[ -n $(yaml_get "$dir/component.yaml" "$key") ]] || fail "$dir/component.yaml: '$key' is missing"
  done
  [[ -f $dir/values.yaml ]] || fail "$dir/values.yaml is missing"
}

# Renders a component into $manifests the way ArgoCD does: its pinned chart and values.
render_component() {
  local args
  mapfile -t args < <(component_helm_args "$1")
  helm template "${1##*/}" "${args[@]}" --include-crds --kube-version "$k8s_version" >"$manifests"
}

# Renders what the root Application syncs into $manifests.
render_gitops() {
  helm template gitops gitops --kube-version "$k8s_version" >"$manifests"
}

kubeconform_args=(
  -strict -summary
  -kubernetes-version "${k8s_version%.*}.0"
  -schema-location default
  # CRD schemas (ArgoCD, Cilium, cert-manager, ESO, Gateway API, Rollouts...).
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
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

log "Justfile"
if just --fmt --check; then
  ok "the Justfile is formatted"
else
  fail "the Justfile isn't formatted; run 'just --fmt'"
fi

log "Components"
mapfile -t components < <(component_dirs)
((${#components[@]})) || fail "no component folders found"
# Each folder's name is its Application's name, and those share one namespace.
duplicates=$(printf '%s\n' "${components[@]##*/}" | sort | uniq -d)
[[ -z $duplicates ]] || fail "component names used twice: $(paste -sd' ' <<<"$duplicates")"
for dir in "${components[@]}"; do
  lint_component_folder "$dir"
  lint_rendering "$dir" render_component "$dir"
done
lint_rendering gitops render_gitops

((fails == 0)) || die "lint found $fails problem(s)"
log "Lint passed"

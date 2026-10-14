#!/usr/bin/env bats
# The root Application's manifest, its patches, and what it says
# (scripts/root-application-state.sh), without a Lab.

setup() {
  # shellcheck source=../root-application-state.sh
  source "$BATS_TEST_DIRNAME/../root-application-state.sh"
}

@test "--revision sets the root Application's revision and its chart's, and nothing else" {
  run root_application_patch --revision my-branch
  [[ $status -eq 0 ]]
  [[ $(yq -o json -I0 . <<<"$output") == \
    '{"spec":{"source":{"targetRevision":"my-branch","helm":{"valuesObject":{"revision":"my-branch"}}}}}' ]]
}

@test "--demos true and --demos false set only whether the Lab has its Demos, as a boolean" {
  run root_application_patch --demos true
  [[ $status -eq 0 ]]
  [[ $(yq -o json -I0 . <<<"$output") == '{"spec":{"source":{"helm":{"valuesObject":{"demos":true}}}}}' ]]
  run root_application_patch --demos false
  [[ $status -eq 0 ]]
  [[ $(yq -o json -I0 . <<<"$output") == '{"spec":{"source":{"helm":{"valuesObject":{"demos":false}}}}}' ]]
}

@test "--revision and --demos together set all three fields" {
  run root_application_patch --revision v1.2 --demos true
  [[ $status -eq 0 ]]
  [[ $(yq '.spec.source.targetRevision' <<<"$output") == v1.2 ]]
  [[ $(yq '.spec.source.helm.valuesObject.revision' <<<"$output") == v1.2 ]]
  [[ $(yq '.spec.source.helm.valuesObject.demos | tag' <<<"$output") == '!!bool' ]]
  [[ $(yq '.spec.source.helm.valuesObject.demos' <<<"$output") == true ]]
}

@test "no options: fails, and prints no patch" {
  run root_application_patch
  [[ $status -ne 0 && -z $output ]]
}

@test "an empty revision: fails, and prints no patch" {
  run root_application_patch --revision ''
  [[ $status -ne 0 && -z $output ]]
}

@test "--demos neither true nor false: fails, and prints no patch" {
  run root_application_patch --demos maybe
  [[ $status -ne 0 && -z $output ]]
}

@test "the manifest is the root Application, with the fixed fields and the three set ones" {
  LAB_REPO=https://example.com/lab.git
  run root_application_manifest my-branch true
  [[ $status -eq 0 ]]
  field() { yq "$1" <<<"$output"; }
  [[ $(field .kind) == Application && $(field .apiVersion) == argoproj.io/v1alpha1 ]]
  [[ $(field .metadata.name) == root && $(field .metadata.namespace) == argocd ]]
  [[ $(field .spec.project) == platform ]]
  [[ $(field .spec.source.repoURL) == https://example.com/lab.git ]]
  [[ $(field .spec.source.path) == gitops ]]
  [[ $(field .spec.source.helm.valuesObject.repoURL) == https://example.com/lab.git ]]
  [[ $(field .spec.destination.server) == https://kubernetes.default.svc ]]
  [[ $(field .spec.destination.namespace) == argocd ]]
  [[ $(field .spec.syncPolicy.automated.prune) == true && $(field .spec.syncPolicy.automated.selfHeal) == true ]]
  [[ $(field '.spec.syncPolicy.syncOptions[0]') == RespectIgnoreDifferences=true ]]
  [[ $(field '.spec.ignoreDifferences[0].kind') == AppProject ]]
  [[ $(field '.spec.ignoreDifferences[0].jsonPointers[0]') == /spec/syncWindows ]]
  [[ $(field .spec.source.targetRevision) == my-branch ]]
  [[ $(field .spec.source.helm.valuesObject.revision) == my-branch ]]
  [[ $(field '.spec.source.helm.valuesObject.demos | tag') == '!!bool' ]]
  [[ $(field .spec.source.helm.valuesObject.demos) == true ]]
}

@test "a manifest without the Demos says so" {
  LAB_REPO=https://example.com/lab.git
  run root_application_manifest v1.2 false
  [[ $status -eq 0 ]]
  [[ $(yq .spec.source.helm.valuesObject.demos <<<"$output") == false ]]
}

@test "a manifest with an empty revision: fails" {
  LAB_REPO=https://example.com/lab.git
  run root_application_manifest '' false
  [[ $status -ne 0 ]]
}

@test "a revision that reads as a number stays a string in the manifest" {
  LAB_REPO=https://example.com/lab.git
  run root_application_manifest 1.0 false
  [[ $status -eq 0 ]]
  [[ $(yq '.spec.source.targetRevision | tag' <<<"$output") == '!!str' ]]
  [[ $(yq '.spec.source.helm.valuesObject.revision | tag' <<<"$output") == '!!str' ]]
}

# root <valuesObject>: the root Application as ArgoCD returns it, with those values.
root() {
  V=$1 yq -n -o json '.metadata.name = "root" | .spec.source.helm.valuesObject = env(V)'
}

@test "the root Application says demos: true: the Lab has its Demos" {
  run lab_has_demos <<<"$(root '{"revision": "main", "demos": true}')"
  [[ $status -eq 0 && $output == true ]]
}

@test "the root Application says demos: false: the Lab has no Demos" {
  run lab_has_demos <<<"$(root '{"revision": "main", "demos": false}')"
  [[ $status -eq 0 && $output == false ]]
}

@test "the root Application doesn't say, as the gitops chart defaults it: the Lab has no Demos" {
  run lab_has_demos <<<"$(root '{"revision": "main"}')"
  [[ $status -eq 0 && $output == false ]]
}

@test "no root Application to read, as when the request failed: fails" {
  run lab_has_demos <<<""
  [[ $status -ne 0 && $output != true && $output != false ]]
}

#!/usr/bin/env bats
# The root Application: its manifest, changing it, and what it says
# (scripts/lib/root-application.sh), without a Lab: kc answers for the Lab.

setup() {
  # shellcheck source=../lib/root-application.sh
  source "$BATS_TEST_DIRNAME/../lib/root-application.sh"
  # shellcheck source=../lib/components.sh
  source "$BATS_TEST_DIRNAME/../lib/components.sh" # need_feature's feature_left_out
  load lab
}

PATCH=(-n argocd patch application/root --type merge --patch-file /dev/stdin)

# patched: the patch kc was handed for the root Application, compacted with sorted keys.
patched() { kc_stdin "${PATCH[@]}" | jq -cS .; }

@test "track sets the root Application's revision and its chart's, with a hard refresh, and nothing else" {
  kc_succeeds "${PATCH[@]}"
  run root_application_track my-branch
  [[ $status -eq 0 ]]
  [[ $(patched) == '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}},"spec":{"source":{"helm":{"valuesObject":{"revision":"my-branch"}},"targetRevision":"my-branch"}}}' ]]
}

@test "set_demos true and false set only whether the Lab has its Demos, as a boolean" {
  kc_succeeds "${PATCH[@]}"
  root_application_set_demos true
  [[ $(patched | jq -c .spec) == '{"source":{"helm":{"valuesObject":{"demos":true}}}}' ]]
  root_application_set_demos false
  [[ $(patched | jq -c .spec) == '{"source":{"helm":{"valuesObject":{"demos":false}}}}' ]]
}

@test "an empty revision, or Demos neither true nor false: fails, and patches nothing" {
  kc_succeeds "${PATCH[@]}"
  run root_application_track ''
  [[ $status -eq 1 && $output == "error: no patch for the root Application from: --revision " ]]
  run root_application_set_demos maybe
  [[ $status -eq 1 && $output == "error: no patch for the root Application from: --demos maybe" ]]
  [[ ! -e $KC_CALLS ]]
}

@test "a patch the Lab refuses: fails" {
  run root_application_track my-branch
  [[ $status -ne 0 ]]
}

@test "the manifest is the root Application, with the fixed fields and the four set ones" {
  run root_application_manifest my-branch true
  [[ $status -eq 0 ]]
  field() { yq "$1" <<<"$output"; }
  [[ $(field .kind) == Application && $(field .apiVersion) == argoproj.io/v1alpha1 ]]
  [[ $(field .metadata.name) == root && $(field .metadata.namespace) == argocd ]]
  [[ $(field .spec.project) == platform ]]
  [[ $(field .spec.source.repoURL) == https://github.com/StefanBS/k3d-lab.git ]]
  [[ $(field .spec.source.path) == gitops ]]
  [[ $(field .spec.source.helm.valuesObject.repoURL) == https://github.com/StefanBS/k3d-lab.git ]]
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
  [[ $(field '.spec.source.helm.valuesObject.without | tag') == '!!seq' ]]
}

@test "a manifest without the Demos says so" {
  run root_application_manifest v1.2 false
  [[ $status -eq 0 ]]
  [[ $(yq .spec.source.helm.valuesObject.demos <<<"$output") == false ]]
}

@test "a manifest without Features lists them, and one with every Feature lists none" {
  run root_application_manifest main false admission-policy observability
  [[ $status -eq 0 ]]
  [[ $(yq -o json -I0 .spec.source.helm.valuesObject.without <<<"$output") == '["admission-policy","observability"]' ]]
  run root_application_manifest main false
  [[ $status -eq 0 ]]
  [[ $(yq -o json -I0 .spec.source.helm.valuesObject.without <<<"$output") == '[]' ]]
}

@test "the patch's --without sets the Features as a list, and an empty one as none" {
  [[ $(root_application_patch --without admission-policy,gpu | jq -c .spec) == '{"source":{"helm":{"valuesObject":{"without":["admission-policy","gpu"]}}}}' ]]
  [[ $(root_application_patch --without '' | jq -c .spec) == '{"source":{"helm":{"valuesObject":{"without":[]}}}}' ]]
  run root_application_patch --without
  [[ $status -eq 1 && -z $output ]]
}

@test "a manifest with an empty revision: fails" {
  run root_application_manifest '' false
  [[ $status -ne 0 ]]
}

@test "a revision that reads as a number stays a string in the manifest" {
  run root_application_manifest 1.0 false
  [[ $status -eq 0 ]]
  [[ $(yq '.spec.source.targetRevision | tag' <<<"$output") == '!!str' ]]
  [[ $(yq '.spec.source.helm.valuesObject.revision | tag' <<<"$output") == '!!str' ]]
}

# has_demos <valuesObject>: what lab_has_demos prints for a root Application with those
# values.
has_demos() {
  V=$1 yq -n -o json '.metadata.name = "root" | .spec.source.helm.valuesObject = env(V)' |
    lab_has_demos
}

@test "the root Application says demos: true: the Lab has its Demos" {
  [[ $(has_demos '{"revision": "main", "demos": true}') == true ]]
}

@test "the root Application says demos: false: the Lab has no Demos" {
  [[ $(has_demos '{"revision": "main", "demos": false}') == false ]]
}

@test "the root Application doesn't say, as the gitops chart defaults it: the Lab has no Demos" {
  [[ $(has_demos '{"revision": "main"}') == false ]]
}

# without <valuesObject>: what root_application_without prints while the root
# Application has those values.
without() {
  V=$1 yq -n -o json '.metadata.name = "root" | .spec.source.helm.valuesObject = env(V)' |
    kc_answers -n argocd get application/root -o json
  root_application_without
}

@test "the root Application lists Features it's without: prints each" {
  [[ $(without '{"revision": "main", "without": ["admission-policy", "gpu"]}') == $'admission-policy\ngpu' ]]
}

@test "the root Application lists none, or doesn't say, as a Lab from before Features: prints nothing" {
  [[ -z $(without '{"revision": "main", "without": []}') ]]
  [[ -z $(without '{"revision": "main"}') ]]
}

@test "the root Application can't be read: fails, saying so" {
  run root_application_without
  [[ $status -eq 1 && $output == "error: can't read the Lab's root Application" ]]
}

@test "need_feature: fails while the Lab is built without the Feature, saying why, and passes while it has it" {
  without '{"revision": "main", "without": ["admission-policy", "gpu"]}' >/dev/null
  run need_feature gpu "the GPU Node can't join it"
  [[ $status -eq 1 && $output == "error: the Lab is built without gpu, so the GPU Node can't join it; 'just down', then a 'just up' that keeps gpu, builds one with it" ]]
  without '{"revision": "main", "without": ["admission-policy"]}' >/dev/null
  run need_feature gpu "the GPU Node can't join it"
  [[ $status -eq 0 && -z $output ]]
  # A Feature whose name is only part of another's isn't the one left out.
  without '{"revision": "main", "without": ["gpu-extra"]}' >/dev/null
  run need_feature gpu "the GPU Node can't join it"
  [[ $status -eq 0 ]]
}

@test "need_feature: the root Application can't be read: fails, saying so" {
  run need_feature gpu "the GPU Node can't join it"
  [[ $status -eq 1 && $output == "error: can't read the Lab's root Application" ]]
}

@test "need_root_application: passes while the Lab has it, and fails without it" {
  run need_root_application
  [[ $status -eq 1 && $output == "error: the Lab has no root Application; run 'just down', then 'just up'" ]]
  kc_answers -n argocd get application/root <<<"application.argoproj.io/root"
  run need_root_application
  [[ $status -eq 0 ]]
}

#!/usr/bin/env bats
# Whether the Lab has its Demos (scripts/demos-state.sh), without a Lab.

setup() {
  # shellcheck source=../demos-state.sh
  source "$BATS_TEST_DIRNAME/../demos-state.sh"
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

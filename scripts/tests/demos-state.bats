#!/usr/bin/env bats
# Whether the Lab has its Demos, and which of their Applications a 'just track' still
# waits for (scripts/demos-state.sh), without a Lab.

setup() {
  # shellcheck source=../demos-state.sh
  source "$BATS_TEST_DIRNAME/../demos-state.sh"
}

# root <valuesObject>: the root Application as ArgoCD returns it, with those values.
root() {
  V=$1 yq -n -o json '.metadata.name = "root" | .spec.source.helm.valuesObject = env(V)'
}

@test "the root Application says demos: true: the Lab has its Demos" {
  run lab_demos <<<"$(root '{"revision": "main", "demos": true}')"
  [[ $status -eq 0 && $output == true ]]
}

@test "the root Application says demos: false: the Lab has no Demos" {
  run lab_demos <<<"$(root '{"revision": "main", "demos": false}')"
  [[ $status -eq 0 && $output == false ]]
}

@test "the root Application doesn't say, as the gitops chart defaults it: the Lab has no Demos" {
  run lab_demos <<<"$(root '{"revision": "main"}')"
  [[ $status -eq 0 && $output == false ]]
}

@test "no root Application to read, as when the request failed: fails" {
  run lab_demos <<<""
  [[ $status -ne 0 && $output != true && $output != false ]]
}

# applications <name>...: the Lab's Applications as ArgoCD lists them, with those names.
applications() {
  jq -n '{"items": [$ARGS.positional[] | {"metadata": {"name": .}}]}' --args "$@"
}

@test "waiting for a Demo's Application that isn't there yet: pending" {
  run demos_pending present rollouts-demo <<<"$(applications root comfyui)"
  [[ $status -eq 0 && $output == rollouts-demo ]]
}

@test "waiting for a Demo's Application that's there: none pending" {
  run demos_pending present rollouts-demo <<<"$(applications root comfyui rollouts-demo)"
  [[ $status -eq 0 && -z $output ]]
}

@test "waiting for a Demo's Application to go while it's still there: pending" {
  run demos_pending gone rollouts-demo <<<"$(applications root comfyui rollouts-demo)"
  [[ $status -eq 0 && $output == rollouts-demo ]]
}

@test "waiting for a Demo's Application to go once it has: none pending" {
  run demos_pending gone rollouts-demo <<<"$(applications root comfyui)"
  [[ $status -eq 0 && -z $output ]]
}

@test "several Demos: only those still pending" {
  run demos_pending present rollouts-demo other-demo third-demo <<<"$(applications root other-demo)"
  [[ $status -eq 0 && $output == $'rollouts-demo\nthird-demo' ]]
}

@test "no Applications to read, as when the request failed: fails" {
  run demos_pending gone rollouts-demo <<<""
  [[ $status -ne 0 ]]
}

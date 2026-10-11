#!/usr/bin/env bats
# Whether the Lab has its Demos, and which of their Applications 'just demos' still
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

# applications <name>[=<sync>,<health>]...: the Lab's Applications as ArgoCD lists them, each
# Synced and Healthy unless it says otherwise. A bare "=" gives one no status yet.
applications() {
  jq -n '{"items": [$ARGS.positional[] | split("=") | {"metadata": {"name": .[0]}} +
    (if length == 1 then {"status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}}
    else (.[1] | split(",")) as $s | {"status": {"sync": {"status": $s[0]}, "health": {"status": $s[1]}}} end)]}' \
    --args "$@"
}

@test "turning the Demos on, before the Demo's Application is generated: pending" {
  run demos_pending ready rollouts-demo <<<"$(applications root comfyui)"
  [[ $status -eq 0 && $output == "rollouts-demo: not generated yet" ]]
}

@test "turning the Demos on, while the Demo's Application syncs: pending, with its state" {
  run demos_pending ready rollouts-demo <<<"$(applications root rollouts-demo=Synced,Progressing)"
  [[ $status -eq 0 && $output == "rollouts-demo: Synced, Progressing" ]]
}

@test "turning the Demos on, when the Demo's Application has no status yet: pending" {
  run demos_pending ready rollouts-demo <<<"$(applications root rollouts-demo=)"
  [[ $status -eq 0 && $output == "rollouts-demo: Unknown, Unknown" ]]
}

@test "turning the Demos on, once the Demo's Application is Synced and Healthy: none pending" {
  run demos_pending ready rollouts-demo <<<"$(applications root comfyui rollouts-demo)"
  [[ $status -eq 0 && -z $output ]]
}

@test "turning the Demos off, while the Demo's Application is still there: pending" {
  run demos_pending gone rollouts-demo <<<"$(applications root comfyui rollouts-demo)"
  [[ $status -eq 0 && $output == rollouts-demo ]]
}

@test "turning the Demos off, once the Demo's Application has gone: none pending" {
  run demos_pending gone rollouts-demo <<<"$(applications root comfyui)"
  [[ $status -eq 0 && -z $output ]]
}

@test "several Demos: only those still pending" {
  run demos_pending ready rollouts-demo other-demo third-demo <<<"$(applications root other-demo)"
  [[ $status -eq 0 && $output == $'rollouts-demo: not generated yet\nthird-demo: not generated yet' ]]
}

@test "no Applications to read, as when the request failed: fails" {
  run demos_pending gone rollouts-demo <<<""
  [[ $status -ne 0 ]]
}

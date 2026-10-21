#!/usr/bin/env bats
# Pausing an Application, resuming it, and which are paused (scripts/lib/pauses.sh),
# without a Lab: kc answers for the Lab.

setup() {
  # shellcheck source=../lib/pauses.sh
  source "$BATS_TEST_DIRNAME/../lib/pauses.sh"
  load lab
}

# The deny window 'just pause comfyui' adds, as ArgoCD lists it.
comfyui_paused='{"kind": "deny", "schedule": "* * * * *", "duration": "1h", "applications": ["comfyui"],
  "manualSync": false, "description": "just pause"}'

# project <syncWindows>: an AppProject, with those sync windows: a JSON array, or "" for
# none.
project() {
  if [[ -n $1 ]]; then
    jq -n --argjson w "$1" '{"metadata": {"resourceVersion": "42"}, "spec": {"syncWindows": $w}}'
  else
    echo '{"metadata": {"resourceVersion": "42"}, "spec": {}}'
  fi
}

# projects <syncWindows>...: while the Lab's AppProjects are those, one per argument.
projects() {
  local windows
  for windows; do project "$windows"; done | jq -s '{"items": .}' |
    kc_answers -n argocd get appprojects -o json
}

# expect <want> <got>
expect() {
  [[ $2 == "$1" ]] || {
    echo "want: $1"
    echo "got:  $2"
    return 1
  }
}

@test "no sync windows: nothing paused" {
  projects "" "[]"
  expect "" "$(paused_applications)"
}

@test "a pause window in each of two projects: both paused" {
  projects "[$comfyui_paused]" "[${comfyui_paused/comfyui/cilium}]"
  expect "comfyui
cilium" "$(paused_applications)"
}

@test "the AppProjects can't be read: fails" {
  run paused_applications
  [[ $status -ne 0 && -z $output ]]
}

# A window of someone else's, which neither pause nor resume touches.
other='{"kind": "allow", "schedule": "0 22 * * *", "duration": "1h", "applications": ["*"]}'

PATCH=(-n argocd patch appproject workloads --type merge --patch-file /dev/stdin)

# windows <pause|resume> <syncWindows>: the sync windows that pausing or resuming comfyui
# sets on its project, which has those, compacted.
windows() {
  kc_answers -n argocd get application comfyui -o 'jsonpath={.spec.project}' <<<workloads
  project "$2" | kc_answers -n argocd get appproject workloads -o json
  kc_succeeds "${PATCH[@]}"
  "$1_application" comfyui
  kc_stdin "${PATCH[@]}" | jq -c .spec.syncWindows
}

@test "pause adds its window, and keeps the others" {
  expect "$(jq -c -n "[$comfyui_paused]")" "$(windows pause "")"
  expect "$(jq -c -n "[$other, $comfyui_paused]")" "$(windows pause "[$other]")"
}

@test "pausing again adds no second window" {
  expect "$(jq -c -n "[$comfyui_paused]")" "$(windows pause "[$comfyui_paused]")"
}

@test "the patch carries the project's resourceVersion, so a change since it was read fails it" {
  windows pause "" >/dev/null
  expect '"42"' "$(kc_stdin "${PATCH[@]}" | jq .metadata.resourceVersion)"
}

@test "resume removes only that Application's pause" {
  expect "$(jq -c -n "[$other, ${comfyui_paused/comfyui/cilium}]")" \
    "$(windows resume "[$other, $comfyui_paused, ${comfyui_paused/comfyui/cilium}]")"
}

@test "resuming what isn't paused changes nothing" {
  expect "[]" "$(windows resume "")"
  expect "$(jq -c -n "[$other]")" "$(windows resume "[$other]")"
}

@test "an Application the Lab doesn't have: fails, saying so, and patches nothing" {
  run pause_application nothing
  [[ $status -eq 1 ]]
  [[ $output == "error: the Lab has no Application named 'nothing'; 'kubectl -n argocd get applications' lists them" ]]
  ! grep -q patch "$KC_CALLS"
}

#!/usr/bin/env bats
# Which Applications 'just pause' has paused (scripts/pause-state.sh), without a Lab:
# each function reads the Lab's AppProjects on stdin.

setup() {
  # shellcheck source=../pause-state.sh
  source "$BATS_TEST_DIRNAME/../pause-state.sh"
}

# The deny window 'just pause comfyui' adds, as ArgoCD lists it.
comfyui_paused='{"kind": "deny", "schedule": "* * * * *", "duration": "1h", "applications": ["comfyui"],
  "manualSync": false, "description": "just pause"}'

# projects <syncWindows>...: the Lab's AppProjects (kubectl get appprojects -o json), one
# per argument, each with those sync windows: a JSON array, or "" for none.
projects() {
  local windows
  for windows; do
    if [[ -n $windows ]]; then jq -n --argjson w "$windows" '{"spec": {"syncWindows": $w}}'; else echo '{"spec": {}}'; fi
  done | jq -s '{"items": .}'
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
  expect "" "$(projects "" "[]" | paused_applications)"
}

@test "a pause window in each of two projects: both paused" {
  expect "comfyui
cilium" "$(projects "[$comfyui_paused]" "[${comfyui_paused/comfyui/cilium}]" | paused_applications)"
}

# A window of someone else's, which neither pause nor resume touches.
other='{"kind": "allow", "schedule": "0 22 * * *", "duration": "1h", "applications": ["*"]}'

# windows <function> <application> <syncWindows>: what that function prints for one
# AppProject with those sync windows, compacted.
windows() { projects "$3" | jq '.items[0]' | "$1" "$2" | jq -c .; }

@test "pause adds its window, and keeps the others" {
  expect "$(jq -c -n "[$comfyui_paused]")" "$(windows pause_windows comfyui "")"
  expect "$(jq -c -n "[$other, $comfyui_paused]")" "$(windows pause_windows comfyui "[$other]")"
}

@test "pausing again adds no second window" {
  expect "$(jq -c -n "[$comfyui_paused]")" "$(windows pause_windows comfyui "[$comfyui_paused]")"
}

@test "resume removes only that Application's pause" {
  expect "$(jq -c -n "[$other, ${comfyui_paused/comfyui/cilium}]")" \
    "$(windows resume_windows comfyui "[$other, $comfyui_paused, ${comfyui_paused/comfyui/cilium}]")"
}

@test "resuming what isn't paused changes nothing" {
  expect "[]" "$(windows resume_windows comfyui "")"
  expect "$(jq -c -n "[$other]")" "$(windows resume_windows comfyui "[$other]")"
}

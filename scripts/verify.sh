#!/usr/bin/env bash
# Checks how the running Lab behaves: runs the Chainsaw tests in verify/, one per check
# (ADR 0004). Exits non-zero if any check fails.
# Any arguments go to `chainsaw test`, such as --include-test-regex chainsaw/<check>.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Without a Lab, every check would fail for the same reason.
lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"
kc get --raw /readyz --request-timeout=10s >/dev/null || die "the Lab doesn't answer"

args=(--config "$LAB_ROOT/verify/.chainsaw.yaml" --test-dir "$LAB_ROOT/verify" --kube-context "$LAB_CONTEXT")
[[ -t 1 ]] || args+=(--no-color)

# The GPU checks, labelled k3d-lab/gpu, run only while the GPU Node is Joined and Ready.
# Left is its normal state, so that says nothing. Joined but NotReady means it's powered
# off (ADR 0002): not a failure, but worth knowing.
gpu_node=$(kc get nodes -l k3d-lab/gpu \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')
if [[ -z $gpu_node ]]; then
  args+=(--selector '!k3d-lab/gpu')
elif [[ $gpu_node != *" True" ]]; then
  warn "the GPU Node ${gpu_node%% *} is Joined but NotReady; its checks are skipped"
  args+=(--selector '!k3d-lab/gpu')
fi
exec chainsaw test "${args[@]}" "$@"

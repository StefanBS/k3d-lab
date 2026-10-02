#!/usr/bin/env bash
# Checks how the running Lab behaves: runs the Chainsaw tests in verify/, one per check
# (ADR 0004). Exits non-zero if any check fails.
# Usage: verify.sh [<check>...] [<chainsaw test flags>...]
# Leading plain words name the checks to run, the folders in verify/; without any, every
# check runs. The rest go to `chainsaw test`, such as --pause-on-failure.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

# The checks that call the Lab from the Host trust only the Lab CA.
export LAB_CA_CERT

# Checked here, because Chainsaw passes when a filter matches no check: a typo would
# otherwise look like success.
checks=()
while (($#)) && [[ $1 != -* ]]; do
  [[ -f $LAB_ROOT/verify/$1/chainsaw-test.yaml ]] || die "no check named '$1'; the checks are the folders in verify/"
  checks+=("$1")
  shift
done

# Without a Lab, every check would fail for the same reason.
lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"
kc get --raw /readyz --request-timeout=10s >/dev/null || die "the Lab doesn't answer"

args=(--config "$LAB_ROOT/verify/.chainsaw.yaml" --test-dir "$LAB_ROOT/verify" --kube-context "$LAB_CONTEXT")
# Only failures, their errors and the summary: a passing step says nothing.
args+=(--quiet)
[[ -t 1 ]] || args+=(--no-color)
# Chainsaw names each check chainsaw/<check>, and matches the regex against that.
((${#checks[@]} == 0)) || args+=(--include-test-regex "^chainsaw/($(IFS='|' && echo "${checks[*]}"))\$")

# The GPU checks, labelled GPU_NODE_LABEL_KEY, run only while the GPU Node is Joined and Ready.
# Left is its normal state, so that says nothing. Joined but NotReady means it's powered
# off (ADR 0002): not a failure, but worth knowing.
gpu_node=$(gpu_node_in_lab)
if [[ $gpu_node != *" True" ]]; then
  [[ -z $gpu_node ]] || warn "the GPU Node ${gpu_node%% *} is Joined but NotReady; its checks are skipped"
  args+=(--selector "!$GPU_NODE_LABEL_KEY")
fi
# The GPU Node routes the Lab's subnet through HOST_LAN_IP, from .env (ADR 0002).
if [[ -n ${HOST_LAN_IP:-} ]] && ! why=$(host_lan_ip_current); then
  warn "$why: the GPU Node's route to the Lab is stale; run 'just host-wizard', then 'just gpu-join'"
fi
# Go's test runner announces every check as it starts, pauses and resumes it, even with
# --quiet. The PASS or FAIL for each check says all of that. With pipefail, the
# pipeline fails if Chainsaw does.
chainsaw test "${args[@]}" "$@" | grep --line-buffered -Ev '^=== (RUN|PAUSE|CONT) '

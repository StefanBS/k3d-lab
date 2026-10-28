#!/usr/bin/env bash
# Checks how the running Lab behaves: runs the Chainsaw tests in verify/, one per check
# (ADR 0004). Exits non-zero if any check fails.
# Usage: [VERBOSE=1] verify.sh [<check>...] [<chainsaw test flags>...]
# Leading plain words name the checks to run, the folders in verify/; without any, every
# check runs. The rest go to `chainsaw test`, such as --pause-on-failure. VERBOSE=1 also
# shows what each passing step did, such as the OK lines of a check's script.
# Run by a Debugging run of up or track, it also warns of a Restart during the run
# (run-diagnostics.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/host.sh
source "$(dirname "$0")/lib/host.sh"
# shellcheck source=lib/run-diagnostics.sh
source "$(dirname "$0")/lib/run-diagnostics.sh"

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

# k3s may stall on its datastore during the run, and the pressure then says why.
record_pressure

# Without a Lab, every check would fail for the same reason.
need_lab
run_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! kc get --raw /readyz --request-timeout=10s >/dev/null; then
  # A Lab that doesn't answer may be k3s restarting, during the run that ran verify.
  diagnose_server failed "$(run_since 10m)" "that may be why"
  die "the Lab doesn't answer"
fi
# Before the Lab's own checks, since k3s may stall while the Host is short on memory.
warn_if_short_on_memory "checks may fail while k3s stalls on its datastore"
# A Restart during up or track leaves a Lab that may pass every check, though k3s died
# while it was built or synced (#135).
if since=$(run_since); then diagnose_server succeeded "$since" "$run_start" "during the run, before verify"; fi

# A paused Application drifts from Git on purpose, so its checks may fail.
while read -r application; do
  warn "$application is paused, so ArgoCD leaves it as it is and its checks may fail; 'just resume $application' puts Git back"
done < <(paused_applications)

# Chainsaw deletes each check's namespace, chainsaw-<random>, and those the check derives
# from it, when the check ends. One still Active is a crashed run's, such as when k3s on
# the Server died mid-run, and its pods still run on a Host short on memory. No run reuses
# the name, so the run doesn't wait for it to go. verify runs one at a time.
mapfile -t leftovers < <(kc get namespaces \
  -o jsonpath='{range .items[?(@.status.phase=="Active")]}{.metadata.name}{"\n"}{end}' | grep '^chainsaw-')
if ((${#leftovers[@]})); then
  warn "deleting the ${#leftovers[@]} namespaces a crashed run left behind"
  kc delete namespace "${leftovers[@]}" --wait=false >/dev/null
fi

args=(--config "$LAB_ROOT/verify/.chainsaw.yaml" --test-dir "$LAB_ROOT/verify" --kube-context "$LAB_CONTEXT")
# Only failures, their errors and the summary: a passing step says nothing.
[[ -n ${VERBOSE:-} ]] || args+=(--quiet)
[[ -t 1 ]] || args+=(--no-color)
# Chainsaw names each check chainsaw/<check>, and matches the regex against that.
((${#checks[@]} == 0)) || args+=(--include-test-regex "^chainsaw/($(IFS='|' && echo "${checks[*]}"))\$")

# The GPU checks, labelled GPU_NODE_LABEL_KEY, run only while the GPU Node's Node object
# is Ready. No Node object means it's Left, its normal state, so that says nothing. A
# NotReady one means it's powered off (ADR 0002), or Left since a reboot: not a failure,
# but worth knowing.
deselected=()
gpu_node=$(gpu_node_object) || exit 1
read -r gpu_node ready <<<"$gpu_node"
if [[ $ready != Ready ]]; then
  [[ -z $ready ]] || warn "the GPU Node's Node object $gpu_node is NotReady: it's off, or Left since a reboot; its checks are skipped"
  deselected+=("!$GPU_NODE_LABEL_KEY")
fi
# The Demos' checks, labelled DEMO_LABEL_KEY, run only while the Lab has its Demos, which
# the root Application says. While it has them, a Demo that's missing fails its checks.
demos=$(root_application_has_demos)
if [[ $demos != true ]]; then
  log "The Lab has no Demos, so their checks are skipped; 'just demos on' adds them"
  deselected+=("!$DEMO_LABEL_KEY")
fi
((${#deselected[@]} == 0)) || args+=(--selector "$(IFS=, && echo "${deselected[*]}")")
# The GPU Node routes the Lab's subnet through HOST_LAN_IP, from .env (ADR 0002).
if [[ -n ${HOST_LAN_IP:-} ]] && ! why=$(host_lan_ip_current); then
  warn "$why: the GPU Node's route to the Lab is stale; run 'just host wizard', then 'just gpu join'"
fi
# Go's test runner announces every check as it starts, pauses and resumes it, even with
# --quiet. The PASS or FAIL for each check says all of that. With pipefail, the
# pipeline fails if Chainsaw does.
if ! chainsaw test "${args[@]}" "$@" | grep --line-buffered -Ev '^=== (RUN|PAUSE|CONT) '; then
  # The Host may have run short during the run, though it wasn't at the start.
  diagnose_server failed "$run_start" "that may be why checks failed"
  exit 1
fi
# Passing checks may still have waited out a Restart, which is worth knowing.
diagnose_server succeeded "$run_start" "checks passed anyway"

#!/usr/bin/env bash
# Checks how the running Lab behaves: runs the Chainsaw tests in verify/, one per check
# (ADR 0004). Exits non-zero if any check fails.
# Usage: [VERBOSE=1] verify.sh [<check>...] [<chainsaw test flags>...]
# Leading plain words name the checks to run, the folders in verify/; without any, every
# check runs. The rest go to `chainsaw test`, such as --pause-on-failure. VERBOSE=1 also
# shows what each passing step did, such as the OK lines of a check's script.
# LAB_UP_SINCE, which up sets, also reports k3s restarts on the Server from that time on,
# before the run.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"
# shellcheck source=host-memory.sh
source "$(dirname "$0")/host-memory.sh"
# shellcheck source=pause-state.sh
source "$(dirname "$0")/pause-state.sh"
# shellcheck source=server-restarts.sh
source "$(dirname "$0")/server-restarts.sh"
# shellcheck source=below.sh
source "$(dirname "$0")/below.sh"

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

# warn_if_short_on_memory <consequence>: WARNs, with the numbers, while the Host is short
# on memory, since k3s then stalls and may die on its own datastore.
warn_if_short_on_memory() {
  local memory
  if memory=$(host_memory_short </proc/meminfo); then warn "Host is short on memory: $memory; $1"; fi
}

# warn_if_server_stalled <since> <consequence> [<until>]: WARNs when k3s on the Server
# restarted since then, and before <until>, given as Docker's --since and --until take
# them, since checks then fail for that reason rather than the change's. When it stalled
# on its datastore, also shows the pressure before, which says what stalled it.
warn_if_server_stalled() {
  local logs restarts stall
  logs=$(docker logs --since "$1" ${3:+--until "$3"} "$LAB_SERVER" 2>&1) || true
  if restarts=$(server_restarts <<<"$logs"); then warn "$restarts; $2"; fi
  if stall=$(server_stall <<<"$logs"); then show_pressure_before "$stall"; fi
}

# docker_disk: the disk under Docker's data root, as diskstats names it, such as sda: the
# k3d Nodes' datastores are there. The disk itself, not the volume or partition on it,
# since swap and the Host's other volumes may share it.
docker_disk() {
  local volume
  volume=$(df --output=source "$(docker info -f '{{.DockerRootDir}}')" | tail -1)
  lsblk -snro NAME,TYPE "$volume" | awk '$2 == "disk" { print $1; found = 1; exit } END { exit !found }'
}

# show_pressure_before <stall>: WARNs with the pressure on the Server's cgroups and the
# Host's disk in the minute before k3s stalled, given as server_stall prints it, from
# what below recorded.
show_pressure_before() {
  local end at id disk args table lines
  end=$(date -ud "${1%% *}" +%s)
  at="k3s on the Server ${1#* } at $(date -ud "@$end" +%T) UTC"
  # below prints its times in the local time zone; k3s logs them in UTC.
  table=$(
    if id=$(docker inspect -f '{{.Id}}' "$LAB_SERVER" 2>/dev/null); then
      mapfile -t args < <(below_server_dump_args "$id" "$end")
      TZ=UTC below --config "$LAB_BELOW_CONFIG" "${args[@]}" 2>/dev/null || true
    fi
    if disk=$(docker_disk 2>/dev/null); then
      mapfile -t args < <(below_disk_dump_args "$disk" "$end")
      TZ=UTC below --config "$LAB_BELOW_CONFIG" "${args[@]}" 2>/dev/null || true
    fi
  ) || true
  if table=$(below_table <<<"$table"); then
    warn "$at; the pressure in the minute before, from below's store ('below --config $LAB_BELOW_CONFIG replay -t $((end - 60))' replays it):"
    mapfile -t lines <<<"$table"
    printf '      %s\n' "${lines[@]}"
  else
    warn "$at; below recorded nothing from the minute before in $LAB_BELOW_DIR"
  fi
}

# Before the Lab's own checks, since memory may be why it doesn't answer.
warn_if_short_on_memory "checks may fail while k3s stalls on its datastore"

# Without a Lab, every check would fail for the same reason.
lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"
run_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! kc get --raw /readyz --request-timeout=10s >/dev/null; then
  # A Lab that doesn't answer may be k3s restarting.
  warn_if_server_stalled 10m "that may be why"
  die "the Lab doesn't answer"
fi
# A restart during up leaves a Lab that may pass every check, though it was built under
# a k3s that died (#135).
if [[ -n ${LAB_UP_SINCE:-} ]]; then
  warn_if_server_stalled "$LAB_UP_SINCE" "during 'just up', before verify" "$run_start"
fi

# A paused Application drifts from Git on purpose, so its checks may fail.
while read -r application; do
  warn "$application is paused, so ArgoCD leaves it as it is and its checks may fail; 'just resume $application' puts Git back"
done < <(kc -n argocd get appprojects -o json | paused_applications)

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
  warn "$why: the GPU Node's route to the Lab is stale; run 'just host wizard', then 'just gpu join'"
fi
# Go's test runner announces every check as it starts, pauses and resumes it, even with
# --quiet. The PASS or FAIL for each check says all of that. With pipefail, the
# pipeline fails if Chainsaw does.
if ! chainsaw test "${args[@]}" "$@" | grep --line-buffered -Ev '^=== (RUN|PAUSE|CONT) '; then
  # The Host may have run short during the run, though it wasn't at the start.
  warn_if_short_on_memory "that may be why checks failed"
  warn_if_server_stalled "$run_start" "that may be why checks failed"
  exit 1
fi
# Passing checks may still have waited out a restart, which is worth knowing.
warn_if_server_stalled "$run_start" "checks passed anyway"

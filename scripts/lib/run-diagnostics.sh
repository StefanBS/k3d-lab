# What to say about the Server once work on the Lab has ended: diagnose_server. Sourced
# after lib.sh by up.sh, track.sh and verify.sh, and on its own by scripts/tests/, so it
# sets no shell options and runs nothing when sourced.
# A Debugging run hands two variables over to the verify it ends with, through the
# environment, since `just verify` takes no such argument:
# - LAB_RUN_SINCE (start_run_clock): from when the run's work counts, as Docker's --since
#   takes it.
# - LAB_BELOW_RECORDING (below.sh's record_pressure): set while below records the Pressure.
# shellcheck shell=bash
# shellcheck source=host-memory.sh
source "$(dirname "${BASH_SOURCE[0]}")/host-memory.sh"
# shellcheck source=server-restarts.sh
source "$(dirname "${BASH_SOURCE[0]}")/server-restarts.sh"
# warn_if_short_on_memory <consequence>: WARNs, with the numbers, while the Host is short
# on memory, since k3s then stalls and may die on its own datastore.
warn_if_short_on_memory() {
  local memory
  if memory=$(host_memory_short </proc/meminfo); then warn "Host is short on memory: $memory; $1"; fi
}

# server_logs <since> [<until>]: the Server's logs between those times, given as Docker's
# --since and --until take them.
server_logs() {
  docker logs --since "$1" ${2:+--until "$2"} "$LAB_SERVER" 2>&1 || true
}

# docker_disk: the disk under Docker's data root, as diskstats names it, such as sda: the
# k3d Nodes' datastores are there. The disk itself, not the volume or partition on it,
# since swap and the Host's other volumes may share it.
docker_disk() {
  local volume ancestry
  volume=$(df --output=source "$(docker info -f '{{.DockerRootDir}}')" | tail -1)
  # Captured first: disk_under stops at the disk, and lsblk could die of the closed pipe.
  ancestry=$(lsblk -snro NAME,TYPE "$volume")
  disk_under <<<"$ancestry"
}

# disk_under < <lsblk -snro NAME,TYPE <volume>>: the disk in the volume's ancestry, which
# lsblk lists from the volume down. Fails when there's none.
disk_under() {
  awk '$2 == "disk" { print $1; found = 1; exit } END { exit !found }'
}

# server_pressure <epoch seconds>: what below recorded in the minute before then, as CSV:
# the Server's cgroups, then the disk under Docker's data root.
server_pressure() {
  local id disk args
  if id=$(docker inspect -f '{{.Id}}' "$LAB_SERVER" 2>/dev/null); then
    mapfile -t args < <(below_server_dump_args "$id" "$1")
    below --config "$LAB_BELOW_CONFIG" "${args[@]}" 2>/dev/null || true
  fi
  if disk=$(docker_disk 2>/dev/null); then
    mapfile -t args < <(below_disk_dump_args "$disk" "$1")
    below --config "$LAB_BELOW_CONFIG" "${args[@]}" 2>/dev/null || true
  fi
}

# pressure_before <cause> < <server_pressure's CSV>: WARNs with the Pressure in the minute
# before the cause, given as server_cause prints it, or that below recorded nothing then.
pressure_before() {
  local end at table lines
  end=$(date -ud "${1%% *}" +%s)
  at="k3s on the Server ${1#* } at $(date -ud "@$end" +%T) UTC"
  if table=$(below_table); then
    warn "$at; the Pressure in the minute before, from below's store ('below --config $LAB_BELOW_CONFIG replay -t $((end - 60))' replays it):"
    mapfile -t lines <<<"$table"
    printf '      %s\n' "${lines[@]}"
  else
    warn "$at; below recorded nothing from the minute before in $LAB_BELOW_DIR"
  fi
}

# show_pressure_before <cause>: pressure_before, from what below recorded.
show_pressure_before() {
  # below prints its times in the local time zone; k3s logs them in UTC.
  TZ=UTC server_pressure "$(date -ud "${1%% *}" +%s)" | pressure_before "$1"
}

# diagnose_server <succeeded|failed> <since> [<until>] <consequence>: WARNs with what may
# explain how the work between those times ended, given as Docker's --since and --until
# take them, the consequence ending each line about it. Work that failed, such as checks or
# a Lab that doesn't answer, says if the Host is short on memory, whether k3s restarted,
# and the Pressure before any Death, Restart or Stall. Work that succeeded says only a
# Restart, and the Pressure before it: it waited out a Stall (#135). The Pressure only
# while below records it.
diagnose_server() {
  local outcome=$1 since=$2 until='' consequence=${!#} logs restarts cause
  (($# < 4)) || until=$3
  [[ $outcome != failed ]] || warn_if_short_on_memory "$consequence"
  logs=$(server_logs "$since" ${until:+"$until"})
  cause=$(server_cause "$outcome" <<<"$logs") || return 0
  if restarts=$(server_restarts <<<"$logs"); then warn "$restarts; $consequence"; fi
  [[ -z ${LAB_BELOW_RECORDING:-} ]] || show_pressure_before "$cause"
}

# start_run_clock: from now, a Restart counts against the run (LAB_RUN_SINCE). Called once
# the run has done what restarts k3s on purpose.
start_run_clock() {
  LAB_RUN_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  export LAB_RUN_SINCE
}

# run_since [<default>]: prints LAB_RUN_SINCE, else the default. Fails when there's neither.
run_since() {
  [[ -n ${LAB_RUN_SINCE:-${1:-}} ]] || return 1
  printf '%s\n' "${LAB_RUN_SINCE:-$1}"
}

# report_run <recipe> <debug>: the EXIT trap of up and track, set once the run starts to
# change the Lab, so a run that refuses to start says only why. debug is non-empty for a
# Debugging run, which by then has handed over to verify if it succeeded: exec keeps no
# trap. A run that failed says what may have stalled k3s.
report_run() {
  local status=$?
  if ((status == 0)); then
    [[ -z ${LAB_RUN_SINCE:-} ]] || diagnose_server succeeded "$LAB_RUN_SINCE" "the run succeeded anyway, and 'just verify' checks the Lab"
    return 0
  fi
  # Stopped by a signal, such as Ctrl-C: nothing went wrong to diagnose.
  ((status < 128)) || return 0
  if [[ -n ${LAB_RUN_SINCE:-} ]]; then
    diagnose_server failed "$LAB_RUN_SINCE" "that may be why it failed"
  else
    warn_if_short_on_memory "that may be why it failed"
  fi
  [[ -n $2 ]] || log "For the next attempt, 'just $1 --debug' records the Pressure and runs every check"
}

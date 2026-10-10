# The diagnostics that need no recorder: whether the Host is short on memory, and whether
# k3s on the Server restarted. Sourced after lib.sh by up.sh, track.sh and verify.sh.
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

# warn_if_server_restarted <since> <consequence>: WARNs when k3s on the Server restarted
# since then, given as Docker's --since takes it.
warn_if_server_restarted() {
  local restarts
  if restarts=$(server_logs "$1" | server_restarts); then warn "$restarts; $2"; fi
}

# A run of up or track is a regular one unless it's given --debug. Both kinds leave the
# same Lab. A debugging run also records the pressure and ends with verify, which prints
# every diagnostic; a regular run stops once every Application is Synced and Healthy.
RUN_DEBUG=''
# From when a restart of k3s on the Server counts against the run, as Docker's --since
# takes it. Empty until the run has done what restarts it on purpose.
RUN_SINCE=''

# report_run <recipe>: the EXIT trap of up and track, set once the run starts to change the
# Lab, so a run that refuses to start says only why. A run that failed says what may have
# stalled k3s. A regular run that succeeded says so only if k3s restarted (#135): a
# debugging run has handed over to verify by then, which reports it.
report_run() {
  local status=$?
  if ((status == 0)); then
    [[ -z $RUN_SINCE ]] || warn_if_server_restarted "$RUN_SINCE" "the run succeeded anyway, and 'just verify' checks the Lab"
    return 0
  fi
  # Stopped by a signal, such as Ctrl-C: nothing went wrong to diagnose.
  ((status < 128)) || return 0
  warn_if_short_on_memory "that may be why it failed"
  [[ -z $RUN_SINCE ]] || warn_if_server_restarted "$RUN_SINCE" "that may be why it failed"
  [[ -n $RUN_DEBUG ]] || log "For the next attempt, 'just $1 --debug' records the pressure and runs every check"
}

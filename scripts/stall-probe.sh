#!/usr/bin/env bash
# Stalls the Server's datastore on purpose, once, and appends what happened to a ledger
# (docs/agents/measuring-the-lab.md): a burst of buffered writes to the filesystem under
# Docker's data root, while it times writes to the API. Fails when the verdict is red.
# Usage: stall-probe.sh <label> [<burst MiB>] [<probe seconds>]
# The label names the variant being tested, such as control or dirty-bytes-256m.
# STALL_PROBE_DIR is where the burst goes; it must be on that filesystem.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=stall-ledger.sh
source "$(dirname "$0")/stall-ledger.sh"

label=${1:-}
burst_mib=${2:-8192}
probe_seconds=${3:-120}
# A tab or a newline in the label would break the ledger's columns.
[[ $label =~ ^[A-Za-z0-9._=+-]+$ && $burst_mib =~ ^[1-9][0-9]*$ && $probe_seconds =~ ^[1-9][0-9]*$ ]] ||
  die "usage: stall-probe.sh <label> [<burst MiB>] [<probe seconds>]; a label is letters, digits and ._=+-"

ledger=$LAB_STATE_DIR/stall-probe.tsv
burst_dir=${STALL_PROBE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/k3d-lab}
burst_file=$burst_dir/stall-probe.burst
# The object the probe writes to, in a namespace no policy or Workload owns.
probe=(-n default configmap stall-probe)

[[ $(docker inspect -f '{{.State.Running}}' "$LAB_SERVER" 2>/dev/null) == true ]] ||
  die "the Server isn't running: 'just up' first"

# The datastore is on the filesystem under Docker's data root, which only root can write
# to, so the burst goes elsewhere on the same filesystem.
mkdir -p "$burst_dir"
docker_root=$(docker info -f '{{.DockerRootDir}}')
filesystem() { df --output=source "$1" | tail -n 1; }
[[ $(filesystem "$burst_dir") == "$(filesystem "$docker_root")" ]] ||
  die "$burst_dir isn't on the filesystem under Docker's data root ($docker_root): set STALL_PROBE_DIR to a directory that is"
free_mib=$(df --output=avail -BM "$burst_dir" | tail -n 1 | tr -dc 0-9)
# A full disk would stall more than the datastore.
((free_mib > burst_mib + 4096)) ||
  die "$burst_dir has ${free_mib} MiB free: too little for a burst of $burst_mib MiB"

burst_pid=
cleanup() {
  [[ -z $burst_pid ]] || kill "$burst_pid" 2>/dev/null || true
  rm -f "$burst_file"
  kc delete "${probe[@]}" --ignore-not-found --wait=false --request-timeout=30s >/dev/null 2>&1 || true
}
trap cleanup EXIT
# An interrupted run cleans up too.
trap 'exit 130' INT TERM

# A crashed run's burst, which its cleanup never reached.
rm -f "$burst_file"
kc create "${probe[@]}" --dry-run=client -o yaml | quietly kc apply -f - ||
  die "can't write to the API before the burst, so the Lab isn't at rest"

record_pressure
start=$EPOCHSECONDS
log "Writing a burst of $burst_mib MiB to $burst_dir, and to the API for at least ${probe_seconds}s"
dd if=/dev/zero of="$burst_file" bs=1M count="$burst_mib" status=none &
burst_pid=$!

# microseconds: the time now. EPOCHREALTIME has six decimals, after a . or a , by locale.
microseconds() { printf '%s' "${EPOCHREALTIME/[.,]/}"; }

# One write a second, each storing a new value, since the API server stores no update
# that changes nothing. A write the stall fails still counts towards the latency. k3s
# logs a slow SQL only once it ends, so the probe goes on until the burst is written and
# a write succeeds again, or for 5 minutes more.
writes=0 max_us=0 stored=1
while ((EPOCHSECONDS - start < probe_seconds)) || kill -0 "$burst_pid" 2>/dev/null || ((!stored)); do
  if ((EPOCHSECONDS - start >= probe_seconds)) && [[ -z ${overrun:-} ]]; then
    overrun=1
    log "Still stalled or writing the burst after ${probe_seconds}s, so the probe goes on"
  fi
  if ((EPOCHSECONDS - start >= probe_seconds + 300)); then
    log "Giving up after 5 minutes more: the row may miss a slow SQL that hasn't ended"
    break
  fi
  before=$(microseconds)
  # In the background, since bash runs a trap only once its foreground command returns,
  # and a stalled write would hold an interrupted run, and its burst, for a minute.
  kc patch "${probe[@]}" --type merge -p "{\"data\":{\"write\":\"$before\"}}" >/dev/null 2>&1 &
  if wait "$!"; then
    stored=1
    writes=$((writes + 1))
  else
    stored=0
  fi
  took=$(($(microseconds) - before))
  ((took <= max_us)) || max_us=$took
  sleep 1
done
if kill -0 "$burst_pid" 2>/dev/null; then die "the burst is still being written, so this run says nothing"; fi
# Not a bare wait, which would also wait for the recorder (docs/agents/shell.md).
wait "$burst_pid" || die "the burst failed, so this run says nothing"
# Reaped, so cleanup has nothing to kill, and the PID may be another process by then.
burst_pid=

if [[ ! -s $ledger ]]; then
  mkdir -p "$LAB_STATE_DIR"
  printf '%s\n' "$STALL_LEDGER_COLUMNS" >"$ledger"
fi
row=$(docker logs --since "$start" "$LAB_SERVER" 2>&1 |
  stall_ledger_row "$(date -u -d "@$start" +%Y-%m-%dT%H:%M:%SZ)" "$label" "$burst_mib" "$writes" \
    "$(printf '%d.%d' $((max_us / 1000000)) $((max_us % 1000000 / 100000)))")
printf '%s\n' "$row" >>"$ledger"

log "$ledger:"
paste <(tr '\t' '\n' <<<"$STALL_LEDGER_COLUMNS") <(tr '\t' '\n' <<<"$row") | column -t >&2
[[ $row == *$'\tgreen' ]] || die "red: the datastore stalled, or k3s died or restarted, during the burst"

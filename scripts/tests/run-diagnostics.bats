#!/usr/bin/env bats
# What scripts/run-diagnostics.sh says about the Server once work has ended, from k3s
# logs and below's CSV rather than the Server's own: diagnose_server's policy, how it
# shows the Pressure, and which disk is under Docker's data root.

setup() {
  # shellcheck source=../run-diagnostics.sh
  source "$BATS_TEST_DIRNAME/../run-diagnostics.sh"
  # lib.sh's, which the module's callers source first.
  warn() { printf 'WARN  %s\n' "$1"; }
  LAB_BELOW_DIR=/home/me/.local/state/k3d-lab/below
  LAB_BELOW_CONFIG=$LAB_BELOW_DIR/below.conf
  # k3s and below's dumps give their times in UTC, whatever the Host's time zone.
  export TZ=America/New_York
  unset LAB_RUN_SINCE LAB_BELOW_RECORDING
}

# The Server's scope, as below names its cgroup.
SCOPE=docker-916acc8a636f8969b504fea9a9cf33a3ac01741e09a1d1657cb1710f01c42511.scope

# pressure_before <cause> < <below's CSV>: the Pressure in the minute before the cause,
# as server_cause prints it.

@test "pressure: the cause in UTC, the table, and how to replay the minute before" {
  run pressure_before "2026-10-09T10:21:01Z died" < <(cat <<CSV
2026-10-09 10:20:59,$SCOPE,0.06%,12.50%,3.10%,0.00%,0.00%,4.3 GB,0,0.0 B/s,1.4 MB/s,
2026-10-09 10:20:59,sda,18 KB/s,124 KB/s,
CSV
  )
  [[ $status -eq 0 ]]
  [[ ${lines[0]} == "WARN  k3s on the Server died at 10:21:01 UTC; the Pressure in the minute before, from below's store ('below --config /home/me/.local/state/k3d-lab/below/below.conf replay -t 1791541201' replays it):" ]]
  [[ ${lines[1]} == "      UTC       cgroup     cpu     io      io-full mem     mem-full memory     majflt  read       write" ]]
  [[ ${lines[2]} == "      10:20:59  Server     0.06%   12.50%  3.10%   0.00%   0.00%    4.3 GB     0       0.0 B/s    1.4 MB/s" ]]
  [[ ${lines[3]} == "      10:20:59  disk sda   -       -       -       -       -        -          -       18 KB/s    124 KB/s" ]]
  [[ ${lines[4]} == "      cpu, io, mem: the share of the time some tasks in the cgroup waited on it (-full: all of them)" ]]
  [[ ${#lines[@]} -eq 5 ]]
}

@test "pressure: nothing recorded in the minute before: says so, and where it looked" {
  run pressure_before "2026-10-09T10:21:00Z logged slow SQL" </dev/null
  [[ $status -eq 0 ]]
  [[ $output == "WARN  k3s on the Server logged slow SQL at 10:21:00 UTC; below recorded nothing from the minute before in /home/me/.local/state/k3d-lab/below" ]]
}

# disk_under < <lsblk -snro NAME,TYPE <volume>>: the disk under the volume, as diskstats
# names it.

@test "disk: a logical volume on a partition: the disk under both" {
  run disk_under < <(printf '%s\n' "fedora-root lvm" "nvme0n1p3 part" "nvme0n1 disk")
  [[ $status -eq 0 ]]
  [[ $output == nvme0n1 ]]
}

@test "disk: a partition: its disk" {
  run disk_under < <(printf '%s\n' "sda3 part" "sda disk")
  [[ $status -eq 0 ]]
  [[ $output == sda ]]
}

@test "disk: no disk under the volume, as a loop device's: fails, printing nothing" {
  run disk_under < <(printf '%s\n' "loop0 loop")
  [[ $status -eq 1 ]]
  [[ -z $output ]]
}

# diagnose_server <succeeded|failed> <since> [<until>] <consequence>, over k3s logs: only
# what reads the Server, below's store and the Host's memory is a stub.

# The lines k3s logged around a restart in #113.
FATAL='time="2026-10-09T10:21:01Z" level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"'
START='time="2026-10-09T10:21:16Z" level=info msg="Starting k3s v1.37.1+k3s1 (356c0254)"'
SLOW='time="2026-10-09T10:21:00Z" level=warning msg="Slow SQL: DELETE FROM kine AS kv WHERE kv.id IN (1)"'

# stub <k3s log line>...: the Server logged those lines, below recorded nothing, and the
# Host has memory to spare unless SHORT says how short it is.
stub() {
  LOGS=$(printf '%s\n' "$@")
  server_logs() { printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/window"; printf '%s\n' "$LOGS"; }
  server_pressure() { :; }
  host_memory_short() { [[ -n ${SHORT:-} ]] && echo "$SHORT"; }
}

RESTARTED="WARN  k3s on the Server restarted 1 time (at 10:21:16 UTC); last fatal error: Transaction commit failed: sql: transaction has already been committed or rolled back"
NOTHING_BEFORE="; below recorded nothing from the minute before in /home/me/.local/state/k3d-lab/below"

@test "diagnose, succeeded: only slow SQL, which it waited out: says nothing (#135)" {
  stub "$SLOW"
  LAB_BELOW_RECORDING=1 SHORT="1 GiB available" run diagnose_server succeeded 2026-10-09T10:00:00Z "checks passed anyway"
  [[ $status -eq 0 ]]
  [[ -z $output ]]
}

@test "diagnose, succeeded: a Death, then a Restart: the Restart, and the Pressure before the Death" {
  stub "$SLOW" "$FATAL" "$START"
  LAB_BELOW_RECORDING=1 run diagnose_server succeeded 2026-10-09T10:00:00Z "checks passed anyway"
  [[ $status -eq 0 ]]
  [[ ${lines[0]} == "$RESTARTED; checks passed anyway" ]]
  [[ ${lines[1]} == "WARN  k3s on the Server died at 10:21:01 UTC$NOTHING_BEFORE" ]]
  [[ ${#lines[@]} -eq 2 ]]
}

@test "diagnose, succeeded: a Restart, while short on memory: the Restart, not the memory" {
  stub "$FATAL" "$START"
  SHORT="1 GiB available" run diagnose_server succeeded 2026-10-09T10:00:00Z "checks passed anyway"
  [[ $status -eq 0 ]]
  [[ $output == "$RESTARTED; checks passed anyway" ]]
}

@test "diagnose: the Pressure only while below records" {
  stub "$FATAL" "$START"
  unset LAB_BELOW_RECORDING
  run diagnose_server failed 2026-10-09T10:00:00Z "that may be why"
  [[ $status -eq 0 ]]
  [[ $output == "$RESTARTED; that may be why" ]]
}

@test "diagnose, failed: only slow SQL: the Pressure before it" {
  stub "$SLOW"
  LAB_BELOW_RECORDING=1 run diagnose_server failed 2026-10-09T10:00:00Z "that may be why checks failed"
  [[ $status -eq 0 ]]
  [[ $output == "WARN  k3s on the Server logged slow SQL at 10:21:00 UTC$NOTHING_BEFORE" ]]
}

@test "diagnose, failed: a Death not yet restarted, short on memory: the memory, the Death, the Pressure" {
  stub "$SLOW" "$FATAL"
  LAB_BELOW_RECORDING=1 SHORT="1 GiB available" run diagnose_server failed 2026-10-09T10:00:00Z "that may be why it failed"
  [[ $status -eq 0 ]]
  [[ ${lines[0]} == "WARN  Host is short on memory: 1 GiB available; that may be why it failed" ]]
  [[ ${lines[1]} == "WARN  k3s on the Server restarted 0 times; last fatal error: Transaction commit failed: sql: transaction has already been committed or rolled back; that may be why it failed" ]]
  [[ ${lines[2]} == "WARN  k3s on the Server died at 10:21:01 UTC$NOTHING_BEFORE" ]]
  [[ ${#lines[@]} -eq 3 ]]
}

@test "diagnose, failed: nothing in the logs: says nothing" {
  stub
  LAB_BELOW_RECORDING=1 run diagnose_server failed 2026-10-09T10:00:00Z "that may be why"
  [[ $status -eq 0 ]]
  [[ -z $output ]]
}

@test "diagnose: the window, with and without its end" {
  stub
  diagnose_server failed 10m "that may be why"
  [[ $(<"$BATS_TEST_TMPDIR/window") == 10m ]]
  diagnose_server succeeded 2026-10-09T10:00:00Z 2026-10-09T10:30:00Z "during the run, before verify"
  [[ $(<"$BATS_TEST_TMPDIR/window") == "2026-10-09T10:00:00Z 2026-10-09T10:30:00Z" ]]
}

# run_since [<default>]: from when the run's work counts, which a run of up or track sets.

@test "run since: the run's start when it's set, else the default, else fails" {
  LAB_RUN_SINCE=2026-10-09T10:00:00Z run run_since 10m
  [[ $status -eq 0 && $output == 2026-10-09T10:00:00Z ]]
  unset LAB_RUN_SINCE
  run run_since 10m
  [[ $status -eq 0 && $output == 10m ]]
  run run_since
  [[ $status -eq 1 && -z $output ]]
}

#!/usr/bin/env bats
# How the Lab runs below (scripts/below.sh): the config it records with, the arguments
# of its recorder, and how verify reads back the minute before k3s stalled.

setup() {
  # shellcheck source=../below.sh
  source "$BATS_TEST_DIRNAME/../below.sh"
}

@test "config: the store and its log in the Lab's directory, since below takes them from no flag" {
  run below_config /home/me/.local/state/k3d-lab/below
  [[ $status -eq 0 ]]
  [[ $output == 'store_dir = "/home/me/.local/state/k3d-lab/below/store"
log_dir = "/home/me/.local/state/k3d-lab/below/log"' ]]
}

@test "record: every 2s, unprivileged, with each cgroup's disk I/O, kept a week and to 2 GiB" {
  run below_record_args
  [[ $status -eq 0 ]]
  [[ $output == "record
--interval-s
2
--compress
--disable-exitstats
--collect-io-stat
--retain-for-s
604800
--store-size-limit
2147483648" ]]
}

# A Server's container ID, which names its cgroup, a scope under system.slice.
ID=916acc8a636f8969b504fea9a9cf33a3ac01741e09a1d1657cb1710f01c42511

# arg <flag> <args>: the value that follows the flag.
arg() { awk -v flag="$1" 'found { print; exit } $0 == flag { found = 1 }' <<<"$2"; }

@test "Server's cgroups: the minute before, in epoch seconds" {
  run below_server_dump_args "$ID" 1791571500
  [[ $status -eq 0 ]]
  [[ ${lines[0]} == dump && ${lines[1]} == cgroup ]]
  [[ $(arg -b "$output") == 1791571440 ]]
  [[ $(arg -e "$output") == 1791571500 ]]
  [[ $(arg -O "$output") == csv ]]
}

@test "Server's cgroups: its scope, k3s and init (containerd), not its pods nor another container" {
  run below_server_dump_args "$ID" 1791571500
  [[ $(arg -s "$output") == full_path ]]
  filter=$(arg -F "$output")
  for path in "/system.slice/docker-$ID.scope" "/system.slice/docker-$ID.scope/k3s" "/system.slice/docker-$ID.scope/init"; do
    grep -qE -- "$filter" <<<"$path"
  done
  for path in "/system.slice/docker-$ID.scope/kubepods" "/system.slice/docker-$ID.scope/kubepods/burstable" \
    "/system.slice/docker-${ID/9/0}.scope" "/system.slice/docker-${ID}xscope/k3s"; do
    ! grep -qE -- "$filter" <<<"$path"
  done
}

@test "Host's disk: only that disk, the minute before" {
  run below_disk_dump_args sda 1791571500
  [[ $status -eq 0 ]]
  [[ ${lines[0]} == dump && ${lines[1]} == disk ]]
  [[ $(arg -b "$output") == 1791571440 && $(arg -e "$output") == 1791571500 ]]
  [[ $(arg -s "$output") == name ]]
  filter=$(arg -F "$output")
  grep -qE -- "$filter" <<<sda
  ! grep -qE -- "$filter" <<<sda3
  ! grep -qE -- "$filter" <<<sdb
}

# below_table < <the cgroups' dump, then the disk's>: a row for each cgroup and the disk
# at each time, the Server's scope named as the Server.

@test "table: each time's cgroups, then the disk, in the cgroups' columns" {
  run below_table < <(cat <<CSV
2026-10-09 18:43:53,docker-$ID.scope,0.07%,0.00%,0.00%,0.00%,0.00%,4.3 GB,?,?,?,
2026-10-09 18:43:53,init,0.00%,0.00%,0.00%,0.00%,0.00%,458 MB,?,?,?,
2026-10-09 18:43:53,k3s,0.06%,0.00%,0.00%,0.00%,0.00%,1 GB,?,?,?,
2026-10-09 18:43:55,docker-$ID.scope,0.06%,12.50%,3.10%,0.00%,0.00%,4.3 GB,0,0.0 B/s,1.4 MB/s,
2026-10-09 18:43:53,sda,12 KB/s,816 KB/s,
2026-10-09 18:43:55,sda,18 KB/s,124 KB/s,
CSV
  )
  [[ $status -eq 0 ]]
  [[ ${lines[0]} == "UTC       cgroup     cpu     io      io-full mem     mem-full memory     majflt  read       write" ]]
  [[ ${lines[1]} == "18:43:53  Server     0.07%   0.00%   0.00%   0.00%   0.00%    4.3 GB     ?       ?          ?" ]]
  [[ ${lines[2]} == "18:43:53  init       0.00%   0.00%   0.00%   0.00%   0.00%    458 MB     ?       ?          ?" ]]
  [[ ${lines[3]} == "18:43:53  k3s        0.06%   0.00%   0.00%   0.00%   0.00%    1 GB       ?       ?          ?" ]]
  [[ ${lines[4]} == "18:43:53  disk sda   -       -       -       -       -        -          -       12 KB/s    816 KB/s" ]]
  [[ ${lines[5]} == "18:43:55  Server     0.06%   12.50%  3.10%   0.00%   0.00%    4.3 GB     0       0.0 B/s    1.4 MB/s" ]]
  [[ ${lines[6]} == "18:43:55  disk sda   -       -       -       -       -        -          -       18 KB/s    124 KB/s" ]]
  [[ ${lines[7]} == "cpu, io, mem: the share of the time some tasks in the cgroup waited on it (-full: all of them)" ]]
  [[ ${#lines[@]} -eq 8 ]]
}

@test "table: nothing recorded in the window: fails, printing nothing" {
  run below_table </dev/null
  [[ $status -eq 1 ]]
  [[ -z $output ]]
}

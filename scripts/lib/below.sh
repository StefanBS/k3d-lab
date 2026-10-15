# How the Lab runs below, which records the pressure on the Host and on each cgroup in
# it while verify, or a debugging run of up or track, runs. Sourced by lib.sh's callers,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# k3s on the Server dies when its datastore stalls for more than about 5s, and its logs
# only say the SQL was slow (#113). What stalled it shows in the pressure on the Server's
# cgroups and in the Host's disk, which below records, and keeps for a replay.

# below_config <dir>: below's config for a store in that directory. below takes the
# store's location only from a config file, never from a flag.
below_config() {
  printf 'store_dir = "%s"\nlog_dir = "%s"\n' "$1/store" "$1/log"
}

# below_record_args: the arguments of `below record`, one per line, for mapfile.
below_record_args() {
  local args=(
    record
    # #113's stalls lasted from 5s to 30s.
    --interval-s 2
    # About 4 MB a minute.
    --compress
    # Its eBPF stats of the processes that exit between samples need root. The cgroups'
    # data is complete without them.
    --disable-exitstats
    # Each cgroup's reads and writes, which named containerd's image unpacking in #113.
    --collect-io-stat
    # A week, within the size: below drops whole days, oldest first.
    --retain-for-s $((7 * 24 * 3600))
    --store-size-limit $((2 * 1024 * 1024 * 1024))
  )
  printf '%s\n' "${args[@]}"
}

# The fields verify shows for each of the Server's cgroups, in the order below_table
# labels them.
BELOW_CGROUP_FIELDS=(
  datetime name
  pressure.cpu_some_pct pressure.io_some_pct pressure.io_full_pct
  pressure.memory_some_pct pressure.memory_full_pct
  mem.total mem.pgmajfault io.rbytes_per_sec io.wbytes_per_sec
)

# below_server_dump_args <Server's container ID> <epoch seconds>: the arguments of the
# `below dump` that prints, as CSV, the Server's cgroups in the minute before then: its
# scope, k3s, and init, which holds containerd and its shims. Not kubepods, the pods.
below_server_dump_args() {
  local scope="/system\\.slice/docker-$1\\.scope"
  printf '%s\n' dump cgroup -b $(($2 - 60)) -e "$2" \
    -s full_path -F "^$scope(/(k3s|init))?\$" \
    -f "${BELOW_CGROUP_FIELDS[@]}" -O csv --disable-title
}

# below_disk_dump_args <disk> <epoch seconds>: the arguments of the `below dump` that
# prints, as CSV, the disk's reads and writes in the minute before then. The disk is its
# name in diskstats, such as sda.
below_disk_dump_args() {
  printf '%s\n' dump disk -b $(($2 - 60)) -e "$2" -s name -F "^$1\$" \
    -f datetime name read_bytes_per_sec write_bytes_per_sec -O csv --disable-title
}

# below_table < <below_server_dump_args's CSV, then below_disk_dump_args's>: prints a
# table with a row for each cgroup and the disk at each time, the disk's reads and writes
# in the cgroups' columns, then what the pressure columns mean. Fails, printing nothing,
# when there are no rows. below's CSV ends each row with a comma, so a cgroup's row has 12
# fields and the disk's 5.
below_table() {
  awk -F, '
    function row(c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11) {
      return sprintf("%-10s%-11s%-8s%-8s%-8s%-8s%-9s%-11s%-8s%-11s%s\n", c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11)
    }
    NF != 12 && NF != 5 { next }
    {
      time = substr($1, 12, 8)
      if (!(time in rows)) times[n++] = time
    }
    NF == 12 {
      name = $2 ~ /^docker-.*\.scope$/ ? "Server" : $2
      rows[time] = rows[time] row(time, name, $3, $4, $5, $6, $7, $8, $9, $10, $11)
    }
    NF == 5 { rows[time] = rows[time] row(time, "disk " $2, "-", "-", "-", "-", "-", "-", "-", $3, $4) }
    END {
      if (!n) exit 1
      printf "%s", row("UTC", "cgroup", "cpu", "io", "io-full", "mem", "mem-full", "memory", "majflt", "read", "write")
      for (i = 0; i < n; i++) printf "%s", rows[times[i]]
      print "cpu, io, mem: the share of the time some tasks in the cgroup waited on it (-full: all of them)"
    }'
}

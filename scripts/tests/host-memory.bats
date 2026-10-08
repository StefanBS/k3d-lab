#!/usr/bin/env bats
# Whether the Host is short on memory (scripts/host-memory.sh), from /proc/meminfo text
# rather than the Host's own: host_memory_short < meminfo prints the numbers, and
# succeeds when the Host is short.

setup() {
  # shellcheck source=../host-memory.sh
  source "$BATS_TEST_DIRNAME/../host-memory.sh"
}

# meminfo <MemAvailable kB> <SwapTotal kB> <SwapFree kB>: /proc/meminfo with those values.
meminfo() {
  printf 'MemTotal:       16307900 kB\nMemFree:          390504 kB\nMemAvailable:   %s kB\nBuffers:           53984 kB\nSwapTotal:      %s kB\nSwapFree:       %s kB\n' "$@"
}

@test "short on available memory: short, with the numbers" {
  run host_memory_short < <(meminfo 838861 16654328 16654328)
  [[ $status -eq 0 ]]
  [[ $output == "0.8 GiB available (warns below 1 GiB), 0.0 GiB in swap (warns above 6 GiB)" ]]
}

@test "heavy swap use: short, with the numbers" {
  run host_memory_short < <(meminfo 3009072 16654328 8263720)
  [[ $status -eq 0 ]]
  [[ $output == "2.9 GiB available (warns below 1 GiB), 8.0 GiB in swap (warns above 6 GiB)" ]]
}

@test "enough available memory and little swap: not short, still with the numbers" {
  run host_memory_short < <(meminfo 3009072 16654328 12008344)
  [[ $status -eq 1 ]]
  [[ $output == "2.9 GiB available (warns below 1 GiB), 4.4 GiB in swap (warns above 6 GiB)" ]]
}

@test "exactly at the thresholds: not short" {
  run host_memory_short < <(meminfo 1048576 16654328 10363192)
  [[ $status -eq 1 ]]
}

@test "no swap at all: only available memory counts" {
  run host_memory_short < <(meminfo 3009072 0 0)
  [[ $status -eq 1 ]]
  run host_memory_short < <(meminfo 500000 0 0)
  [[ $status -eq 0 ]]
}

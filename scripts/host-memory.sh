# Whether the Host is short on memory. Sourced by verify.sh and doctor.sh, and on its own
# by scripts/tests/, so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# A sync or a verify run makes the k3d Nodes grow for a while, within their caps
# (k3d/cluster.yaml); below this much available memory, that growth goes to swap.
HOST_MEM_AVAILABLE_MIN_GIB=1
# With the Lab settled and a desktop open, the Host keeps about 4.5 GiB in swap and the
# Lab works. At about 8 GiB, the Server's k3s died on its own datastore, its commits
# stalled behind swapped-out pages (#73).
HOST_SWAP_USED_MAX_GIB=6

# host_memory_short < /proc/meminfo: prints the available memory and the swap in use,
# and succeeds, when either is past its threshold. Otherwise prints nothing and fails.
host_memory_short() {
  awk -v min="$HOST_MEM_AVAILABLE_MIN_GIB" -v max="$HOST_SWAP_USED_MAX_GIB" '
    { kb[$1] = $2 }
    END {
      gib = 1024 * 1024
      avail = kb["MemAvailable:"] / gib
      swap = (kb["SwapTotal:"] - kb["SwapFree:"]) / gib
      if (avail >= min && swap <= max) exit 1
      printf "the Host is short on memory: %.1f GiB available (warns below %s GiB), %.1f GiB in swap (warns above %s GiB)\n", avail, min, swap, max
    }'
}

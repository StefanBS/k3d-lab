# A stall probe's row in its ledger, from the Server's logs. Sourced by stall-probe.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# The ledger's columns, as stall_ledger_row prints them. Seconds for both durations.
# shellcheck disable=SC2034 # stall-probe.sh writes them as the header.
STALL_LEDGER_COLUMNS=$'time\tlabel\tburst_mib\tapi_writes\tapi_max_s\tslowest_slow_sql_s\tfatals\trestarts\tverdict'

# A slow SQL this long is a stall: k3s gives a compaction 5s, and dies when one takes
# longer (#113).
STALL_SECONDS=5

# stall_ledger_row <time> <label> <burst MiB> <API writes> <max latency> < <k3s logs>:
# prints the run's row. Give it only the logs since the burst began. The verdict is red
# when the slowest slow SQL took STALL_SECONDS or more, k3s logged a fatal error, or the
# Server restarted. The API's latency is in the row but never in the verdict: it also
# counts webhooks and the client's own stalls.
stall_ledger_row() {
  awk -v OFS='\t' -v run="$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5" -v stall="$STALL_SECONDS" '
    # A duration as Go prints it, in seconds: 850ms, 1.47s, 1m5.2s.
    function seconds(d,    total, n, unit) {
      while (match(d, /^[0-9.]+/)) {
        n = substr(d, 1, RLENGTH) + 0
        d = substr(d, RLENGTH + 1)
        match(d, /^[^0-9.]+/)
        unit = substr(d, 1, RLENGTH)
        d = substr(d, RLENGTH + 1)
        if (unit == "h") n *= 3600
        else if (unit == "m") n *= 60
        else if (unit == "ms") n /= 1000
        else if (unit != "s") n = 0 # Microseconds and below.
        total += n
      }
      return total
    }
    # The duration follows the statement, which may itself hold anything.
    /msg="Slow SQL/ && match($0, /" duration=[^ ]+ name=/) {
      took = seconds(substr($0, RSTART + 11, RLENGTH - 17))
      if (took > slowest) slowest = took
    }
    /level=fatal/ { fatals++ }
    # Not "Starting k3s.cattle.io/v1, Kind=Addon controller", which every start logs too.
    /msg="Starting k3s v/ { restarts++ }
    END {
      red = slowest >= stall || fatals || restarts
      print run, sprintf("%.1f", slowest), fatals + 0, restarts + 0, red ? "red" : "green"
    }'
}

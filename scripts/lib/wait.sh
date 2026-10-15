# How the scripts wait for the Lab. Sourced by lib.sh, which gives it log and die, and
# on its own by scripts/tests/, so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# wait_until_none <seconds> <what's late> <command>...: runs the command every 5 seconds
# until it prints nothing, each line it prints being something still pending. Logs what's
# pending whenever that changes, and gives up after that many seconds.
wait_until_none() {
  local seconds=$1 late=$2 pending last=''
  shift 2
  local deadline=$((SECONDS + seconds))
  while :; do
    # A sync can be heavy enough for k3s to restart, so a failed command is waited out too.
    pending=$("$@" 2>/dev/null) || pending="the Lab's API isn't answering"
    [[ -n $pending ]] || return 0
    if [[ $pending != "$last" ]]; then
      log "Still waiting: $(wait_summary <<<"$pending")"
      last=$pending
    fi
    ((SECONDS < deadline)) || die "$late after $((seconds / 60)) minutes:"$'\n'"$pending"
    sleep 5
  done
}

# How wait_until_none logs what's pending, which it reads on stdin: the lines that say
# "<name>: <why>" grouped by why, as "<why>: <name> <name>", in the order each first
# appears, so thirty Applications that are all OutOfSync fit on one line. Any other line
# is logged as it is.
wait_summary() {
  awk '
    {
      at = index($0, ": ")
      if (at) { why = substr($0, at + 2); name = substr($0, 1, at - 1) } else { why = $0; name = "" }
      if (!(why in names)) { order[++n] = why; names[why] = "" }
      if (name != "") names[why] = names[why] " " name
    }
    END {
      for (i = 1; i <= n; i++) {
        why = order[i]
        printf "%s%s%s", (i > 1 ? "; " : ""), why, (names[why] == "" ? "" : ":" names[why])
      }
      print ""
    }'
}

# retry <tries> <command>...: runs the command once a second until it succeeds, giving
# up after that many tries.
retry() {
  local tries=$1
  shift
  until "$@"; do
    ((--tries > 0)) || return 1
    sleep 1
  done
}

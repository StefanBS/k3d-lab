# Whether k3s on the Server restarted or stalled, from its logs. Sourced by verify.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# Under load, k3s can die on its own datastore and Docker restarts it (#113). Checks then
# fail in ways that read like regressions. Docker's RestartCount misses it: a later
# `docker start` resets the count, so the logs are what tell.

# field(name), for awk: the value of name="..." on this line.
# shellcheck disable=SC2016 # $0 is awk's, not the shell's.
SERVER_LOG_FIELD='
  function field(name) {
    if (!match($0, name "=\"[^\"]*\"")) return ""
    return substr($0, RSTART + length(name) + 2, RLENGTH - length(name) - 3)
  }'

# server_restarts < <k3s logs>: prints when k3s started and its last fatal error, and
# succeeds when the logs have either. Give it only the logs since the run began.
server_restarts() {
  awk "$SERVER_LOG_FIELD"'
    # Not "Starting k3s.cattle.io/v1, Kind=Addon controller", which every start logs too.
    /msg="Starting k3s v/ {
      time = field("time")
      starts = starts (n++ ? ", " : "") substr(time, 12, 8)
    }
    /level=fatal/ { fatal = field("msg") }
    END {
      if (!n && fatal == "") exit 1
      printf "k3s on the Server restarted %d time%s", n, n == 1 ? "" : "s"
      if (n) printf " (at %s UTC)", starts
      printf "; %s\n", fatal == "" ? "no fatal error logged" : "last fatal error: " fatal
    }'
}

# server_stall < <k3s logs>: prints the stall that says most about why k3s failed, as the
# logs give its time, and what k3s did then. The first death, since a later one may only
# follow from it; else the first restart, as after the OOM killer, which logs no fatal
# error; else the first slow SQL. Fails when k3s did none of them.
server_stall() {
  awk "$SERVER_LOG_FIELD"'
    /level=fatal/ && died == "" { died = field("time") }
    /msg="Starting k3s v/ && restarted == "" { restarted = field("time") }
    /msg="Slow SQL/ && slow == "" { slow = field("time") }
    END {
      if (died != "") print died, "died"
      else if (restarted != "") print restarted, "restarted"
      else if (slow != "") print slow, "logged slow SQL"
      else exit 1
    }'
}

#!/usr/bin/env bats
# Whether k3s on the Server restarted (scripts/server-restarts.sh), from log text rather
# than the Server's own: server_restarts < logs prints when it started and its last
# fatal error, and succeeds when there was either.

setup() {
  # shellcheck source=../server-restarts.sh
  source "$BATS_TEST_DIRNAME/../server-restarts.sh"
}

# The lines k3s logged around a restart in #113.
FATAL='time="2026-10-09T10:21:01Z" level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"'
START_1='time="2026-10-09T10:21:16Z" level=info msg="Starting k3s v1.37.1+k3s1 (356c0254)"'
START_2='time="2026-10-09T10:26:06Z" level=info msg="Starting k3s v1.37.1+k3s1 (356c0254)"'
ADDON='time="2026-10-09T10:21:31Z" level=info msg="Starting k3s.cattle.io/v1, Kind=Addon controller"'
SLOW='time="2026-10-09T10:21:00Z" level=warning msg="Slow SQL: DELETE FROM kine AS kv WHERE kv.id IN (1)"'

@test "a fatal error, then a restart: says when, and the error" {
  run server_restarts < <(printf '%s\n' "$SLOW" "$FATAL" "$START_1" "$ADDON")
  [[ $status -eq 0 ]]
  [[ $output == "k3s on the Server restarted 1 time (at 10:21:16 UTC); last fatal error: Transaction commit failed: sql: transaction has already been committed or rolled back" ]]
}

@test "two restarts, one without a fatal error: both times, still the error" {
  run server_restarts < <(printf '%s\n' "$FATAL" "$START_1" "$ADDON" "$START_2")
  [[ $status -eq 0 ]]
  [[ $output == "k3s on the Server restarted 2 times (at 10:21:16, 10:26:06 UTC); last fatal error: Transaction commit failed: sql: transaction has already been committed or rolled back" ]]
}

@test "a restart without a fatal error, such as docker start: says so" {
  run server_restarts < <(printf '%s\n' "$START_2" "$ADDON")
  [[ $status -eq 0 ]]
  [[ $output == "k3s on the Server restarted 1 time (at 10:26:06 UTC); no fatal error logged" ]]
}

@test "a fatal error, not yet restarted: says so" {
  run server_restarts < <(printf '%s\n' "$SLOW" "$FATAL")
  [[ $status -eq 0 ]]
  [[ $output == "k3s on the Server restarted 0 times; last fatal error: Transaction commit failed: sql: transaction has already been committed or rolled back" ]]
}

@test "only the Addon controller starting, and slow SQL: no restart" {
  run server_restarts < <(printf '%s\n' "$SLOW" "$ADDON")
  [[ $status -eq 1 ]]
  [[ -z $output ]]
}

@test "no logs: no restart" {
  run server_restarts < /dev/null
  [[ $status -eq 1 ]]
  [[ -z $output ]]
}

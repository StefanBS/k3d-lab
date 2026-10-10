#!/usr/bin/env bats
# A stall probe's ledger row (scripts/stall-ledger.sh), from log text rather than the
# Server's own: stall_ledger_row <time> <label> <burst MiB> <API writes> <max latency>
# < logs prints the row, whose last column is the verdict.

setup() {
  # shellcheck source=../stall-ledger.sh
  source "$BATS_TEST_DIRNAME/../stall-ledger.sh"
}

# slow <duration>: a slow SQL line as k3s logs it, the duration after the statement.
slow() {
  printf '%s\n' "time=\"2026-10-10T01:43:33Z\" level=info msg=\"Slow SQL: INSERT INTO kine(name, value) SELECT '/registry/leases/kube-system/x', [5620]byte(...)\" duration=$1 name=InsertLastInsertID started=\"2026-10-10T01:43:30.404280393Z\""
}

FATAL='time="2026-10-09T10:21:01Z" level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"'
START='time="2026-10-09T10:21:16Z" level=info msg="Starting k3s v1.37.1+k3s1 (356c0254)"'
ADDON='time="2026-10-09T10:21:31Z" level=info msg="Starting k3s.cattle.io/v1, Kind=Addon controller"'

# row < logs: the row of one fixed run, so each test reads only the columns the logs decide.
row() {
  stall_ledger_row 2026-10-10T01:43:00Z control 8192 57 2.1
}

@test "slow SQL in seconds: the slowest as a number, not as a string" {
  run row < <(slow 9.9s; slow 30.123456789s; slow 3.530864104s)
  [[ $status -eq 0 ]]
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t30.1\t0\t0\tred' ]]
}

@test "slow SQL in milliseconds: under a second, so green" {
  run row < <(slow 870ms; slow 120.5ms)
  [[ $status -eq 0 ]]
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t0.9\t0\t0\tgreen' ]]
}

@test "slow SQL over a minute: minutes and seconds add up" {
  run row < <(slow 1m5.25s)
  [[ $status -eq 0 ]]
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t65.2\t0\t0\tred' ]]
}

@test "no slow SQL, only the Addon controller starting: green, and no restart" {
  run row < <(printf '%s\n' "$ADDON")
  [[ $status -eq 0 ]]
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t0.0\t0\t0\tgreen' ]]
}

@test "no logs: green" {
  run row < /dev/null
  [[ $status -eq 0 ]]
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t0.0\t0\t0\tgreen' ]]
}

@test "slow SQL of exactly 5s: red" {
  run row < <(slow 5s)
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t5.0\t0\t0\tred' ]]
}

@test "slow SQL just under 5s: green" {
  run row < <(slow 4.94s)
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t4.9\t0\t0\tgreen' ]]
}

@test "k3s died twice with fast SQL: both counted, and red" {
  run row < <(slow 1.2s; printf '%s\n' "$FATAL" "$FATAL")
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t1.2\t2\t0\tred' ]]
}

@test "the Server restarted without a fatal error, as after the OOM killer: red" {
  run row < <(printf '%s\n' "$START" "$ADDON")
  [[ $output == $'2026-10-10T01:43:00Z\tcontrol\t8192\t57\t2.1\t0.0\t0\t1\tred' ]]
}

@test "the columns name every field of a row" {
  row=$(row < /dev/null)
  [[ $(tr -cd '\t' <<<"$STALL_LEDGER_COLUMNS" | wc -c) == $(tr -cd '\t' <<<"$row" | wc -c) ]]
}

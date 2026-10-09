#!/usr/bin/env bash
# Records with below into the Lab's store (scripts/below.sh) until the script that
# started it exits. lib.sh's sample_pressure starts it.
# Usage: below-recorder.sh <PID>
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=below.sh
source "$(dirname "$0")/below.sh"

parent=$1

# below logs where the config says, and only into a directory that exists.
mkdir -p "$LAB_BELOW_DIR"/{store,log}
below_config "$LAB_BELOW_DIR" >"$LAB_BELOW_CONFIG"
mapfile -t args < <(below_record_args)
below --config "$LAB_BELOW_CONFIG" "${args[@]}" &
recorder=$!

while kill -0 "$parent" 2>/dev/null && kill -0 "$recorder" 2>/dev/null; do sleep 1; done

# below 0.9.0 logs "Stop signal received" on TERM or INT and keeps running. A store it
# leaves on KILL reads back intact, so it gets a few seconds to stop on its own first.
kill -TERM "$recorder" 2>/dev/null || exit 0
for _ in 1 2 3; do
  sleep 1
  kill -0 "$recorder" 2>/dev/null || exit 0
done
kill -KILL "$recorder" 2>/dev/null || true

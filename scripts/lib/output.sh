# How the scripts print: what they log, how they fail, and the one line per check.
# Sourced by lib.sh, and on its own by scripts/tests/, so it sets no shell options and
# runs nothing when sourced.
# shellcheck shell=bash
# shellcheck disable=SC2034  # fails is read by the scripts that source this file

log() { printf '==> %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Runs a command, showing its output only if it fails. For tools like k3d and helm,
# whose progress logs and release notes would bury the Lab's own messages.
quietly() {
  local out status=0
  out=$("$@" 2>&1) || status=$?
  ((status == 0)) || printf '%s\n' "$out" >&2
  return "$status"
}

# For the scripts that report one line per check: doctor, lint and the host setup
# scripts print with these. doctor and lint count their failures in fails, and exit
# non-zero if there are any.
fails=0
ok() { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

# What scripts/lib.sh gives the modules in scripts/lib/, for the tests that source one on
# its own: bats' `load lab` in setup. Everything prints to stdout, which `run` captures.
# shellcheck shell=bash

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*"
  exit 1
}
ok() { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; }
# Moves the clock on instead of waiting, so a wait's deadline passes at once.
sleep() { SECONDS=$((SECONDS + $1)); }

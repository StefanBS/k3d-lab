# What scripts/lib.sh gives the modules in scripts/lib/, for the tests that source one on
# its own: bats' `load lab` in setup. The modules lib.sh sources first, as they are, with
# stand-ins for the commands that would reach the Lab or wait. log and die print to
# stderr, which `run` captures with stdout.
# shellcheck shell=bash

for module in output lab lab-repo wait; do
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../lib/$module.sh"
done

# Moves the clock on instead of waiting, so a wait's deadline passes at once.
sleep() { SECONDS=$((SECONDS + $1)); }
# The Lab exists.
need_lab() { :; }

# kc stands in for kubectl against the Lab. It prints what kc_answers set up for exactly
# its arguments, and fails, printing nothing, for any other call, as a failed request
# does. It logs each call's arguments to KC_CALLS, one line each, and keeps what it read
# when it was handed stdin as a file, such as a patch from --patch-file /dev/stdin, for
# kc_stdin.
KC_ANSWERS=$BATS_TEST_TMPDIR/kc
KC_STDIN=$BATS_TEST_TMPDIR/kc-stdin
KC_CALLS=$BATS_TEST_TMPDIR/kc-calls
kc() {
  local key
  key=$(kc_key "$@")
  printf '%s\n' "$*" >>"$KC_CALLS"
  if [[ " $* " == *" /dev/stdin "* ]]; then
    mkdir -p "$KC_STDIN"
    cat >"$KC_STDIN/$key"
  fi
  [[ -f $KC_ANSWERS/$key ]] && cat "$KC_ANSWERS/$key"
}
kc_key() { printf '%s' "$*" | sha1sum | cut -d' ' -f1; }
# kc_answers <kc argument>... < <answer>: what kc prints when called with those arguments.
kc_answers() {
  mkdir -p "$KC_ANSWERS"
  cat >"$KC_ANSWERS/$(kc_key "$@")"
}
# kc_succeeds <kc argument>...: kc succeeds with those arguments, printing nothing.
kc_succeeds() { kc_answers "$@" </dev/null; }
# kc_stdin <kc argument>...: what kc read on stdin when last called with those arguments.
kc_stdin() { cat "$KC_STDIN/$(kc_key "$@")"; }

# still_pending <wait> <argument>...: runs a wait, such as wait_settled, given no time, and
# prints what it said was still pending, or nothing when it passed.
still_pending() {
  local out
  out=$("$1" 0 "${@:2}" 2>&1) && return 0
  sed '1,/ after 0 minutes:$/d' <<<"$out"
}

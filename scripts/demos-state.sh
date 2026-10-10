# Whether the Lab has its Demos, and which of their Applications 'just track' still waits
# for. Sourced by track.sh and verify.sh, and on its own by scripts/tests/, so it sets no
# shell options and runs nothing when sourced.
# shellcheck shell=bash

# lab_demos: reads the root Application (kubectl get application/root -o json) on stdin,
# and prints true if the Lab has its Demos, false otherwise.
lab_demos() {
  # input fails when there's nothing to read, where a plain filter would print nothing.
  jq -rn 'input | .spec.source.helm.valuesObject.demos == true'
}

# demos_pending <present|gone> <name>...: reads the Lab's Applications (kubectl get
# applications -o json) on stdin, and prints each of the named ones that isn't yet present,
# or gone, one per line.
demos_pending() {
  local want=$1
  shift
  jq -rn --arg want "$want" '[input.items[].metadata.name] as $have |
    $ARGS.positional[] | select(IN($have[]) != ($want == "present"))' --args "$@"
}

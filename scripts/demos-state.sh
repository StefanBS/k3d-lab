# Whether the Lab has its Demos, and which of their Applications 'just demos' still waits
# for. Sourced by demos.sh and verify.sh, and on its own by scripts/tests/, so it sets no
# shell options and runs nothing when sourced.
# shellcheck shell=bash

# lab_has_demos: reads the root Application (kubectl get application/root -o json) on stdin,
# and prints true if the Lab has its Demos, false otherwise.
lab_has_demos() {
  # input fails when there's nothing to read, where a plain filter would print nothing.
  jq -rn 'input | .spec.source.helm.valuesObject.demos == true'
}

# demos_pending <ready|gone> <name>...: reads the Lab's Applications (kubectl get
# applications -o json) on stdin, and prints a line for each of the named ones that isn't
# yet Synced and Healthy, saying why, or that isn't yet gone.
demos_pending() {
  local want=$1
  shift
  # shellcheck disable=SC2016 # $have, $want and $name are jq's, not the shell's.
  jq -rn --arg want "$want" '
    (input.items | map({"key": .metadata.name,
      "value": ((.status.sync.status // "Unknown") + ", " + (.status.health.status // "Unknown"))}) |
      from_entries) as $have |
    $ARGS.positional[] | . as $name |
    if $want == "gone" then select($have[$name] != null)
    else select($have[$name] != "Synced, Healthy") | $name + ": " + ($have[$name] // "not generated yet")
    end' --args "$@"
}

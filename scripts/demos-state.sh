# Whether the Lab has its Demos. Sourced by verify.sh, and on its own by scripts/tests/,
# so it sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# lab_has_demos: reads the root Application (kubectl get application/root -o json) on stdin,
# and prints true if the Lab has its Demos, false otherwise.
lab_has_demos() {
  # input fails when there's nothing to read, where a plain filter would print nothing.
  jq -rn 'input | .spec.source.helm.valuesObject.demos == true'
}

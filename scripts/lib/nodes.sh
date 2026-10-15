# Which of the Lab's nodes aren't Ready yet. Sourced by lib.sh, whose wait_nodes_ready
# waits on it, and on its own by scripts/tests/, so it sets no shell options and runs
# nothing when sourced.
# shellcheck shell=bash

# nodes_unready: reads the Lab's nodes (kubectl get nodes -o json) on stdin, and prints
# "<name>: NotReady" for each whose Ready condition isn't True, which kubectl also shows
# for Unknown. A list with no nodes prints "no nodes yet", so a selector that matches
# nothing is waited out, not passed. Fails when there's nothing to read, as when the
# request failed.
nodes_unready() {
  jq -rn '[input.items[]] as $listed |
    if ($listed | length) == 0 then "no nodes yet"
    else
      $listed[] | select(([.status.conditions[]? | select(.type == "Ready")][0].status) != "True") |
      "\(.metadata.name): NotReady"
    end'
}

# The Lab's nodes: waiting for them to be Ready. Sourced by lib.sh, and on its own by
# scripts/tests/, so it sets no shell options and runs nothing when sourced.
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

# wait_nodes_ready <seconds> [<kubectl get option>...]: waits until the Lab's nodes, or
# those the options select, such as -l <label>, are Ready. Gives up after that many seconds.
wait_nodes_ready() {
  local seconds=$1
  shift
  wait_until_none "$seconds" "these nodes aren't Ready" nodes_in_lab_unready "$@"
}
nodes_in_lab_unready() { kc get nodes -o json "$@" | nodes_unready; }

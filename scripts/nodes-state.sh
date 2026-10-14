# Which of the Lab's nodes aren't Ready yet. Sourced by lib.sh, whose wait_nodes_ready
# waits on it, and on its own by scripts/tests/, so it sets no shell options and runs
# nothing when sourced.
# shellcheck shell=bash

# nodes_unready: reads the Lab's nodes (kubectl get nodes -o json) on stdin, and prints
# "<name>: NotReady" for each whose Ready condition isn't True, as kubectl shows it. Fails
# when there's nothing to read, as when the request failed.
nodes_unready() {
  jq -rn 'input.items[] |
    select(([.status.conditions[]? | select(.type == "Ready")][0].status) != "True") |
    "\(.metadata.name): NotReady"'
}

# The Lab's namespaces: deleting them, and waiting for them to be gone. Sourced by lib.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# namespaces_left <name>...: reads the Lab's namespaces (kubectl get namespaces -o json)
# on stdin, and prints "<name>: still there" for each named one that's still listed, as
# it is while it's terminating. Fails when there's nothing to read, as when the request
# failed.
namespaces_left() {
  jq -rn '[input.items[].metadata.name] as $listed |
    $ARGS.positional[] | select(IN($listed[])) | "\(.): still there"' --args "$@"
}

# delete_namespaces <seconds> <name>...: deletes those namespaces, and waits until they're
# gone. Gives up after that many seconds.
delete_namespaces() {
  local seconds=$1
  shift
  wait_until_none "$seconds" "these namespaces aren't gone" namespaces_in_lab_left "$@"
}
# Asks again each time, so a request that failed while k3s restarted is only "not yet".
namespaces_in_lab_left() {
  kc delete namespace "$@" --ignore-not-found --wait=false >/dev/null &&
    kc get namespaces -o json | namespaces_left "$@"
}

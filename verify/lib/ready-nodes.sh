#!/usr/bin/env bash
# Prints the name of every Ready node, one per line, the GPU Node included when it's
# Joined and powered on. Called by the checks' scripts, whose kubectl already points at
# the Lab.
# Usage: ready-nodes.sh [--not-ready] [<kubectl get nodes args>...]
# --not-ready prints the other nodes instead; the rest, such as -l, go to kubectl.
set -euo pipefail

ready=True
if [[ ${1:-} == --not-ready ]]; then
  ready=other
  shift
fi
kubectl get nodes "$@" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
  awk -v ready="$ready" '($2 == "True") == (ready == "True") { print $1 }'

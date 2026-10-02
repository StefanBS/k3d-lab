#!/usr/bin/env bash
# Prints the name of every Ready node, one per line, the GPU Node included when it's
# Joined and powered on. Called by the checks' scripts, whose kubectl already points at
# the Lab.
set -euo pipefail

kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
  awk '$2 == "True" { print $1 }'

#!/usr/bin/env bash
# Checks that every ValidatingPolicy in Git (platform/kyverno-policies/) is in the Lab
# and Ready: Kyverno compiled it and set up its webhook. A new Lab's policies take a
# while, so it retries for 2m.
# Run by kyverno-healthy, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

mapfile -t policies < <(yq -N 'select(.kind == "ValidatingPolicy") | .metadata.name' \
  "$(dirname "$0")"/../../platform/kyverno-policies/*.yaml)
((${#policies[@]})) || {
  echo "FAIL  no ValidatingPolicy in platform/kyverno-policies/"
  exit 1
}

# Prints each policy that isn't Ready yet.
unready_policies() {
  local ready policy
  ready=$(kubectl get validatingpolicies \
    -o jsonpath='{range .items[?(@.status.conditionStatus.ready==true)]}{.metadata.name}{"\n"}{end}' 2>&1) || ready=""
  for policy in "${policies[@]}"; do
    grep -qxF "$policy" <<<"$ready" || echo "$policy"
  done
}

eventually 'policy %s is not Ready' "${policies[@]}" -- unready_policies

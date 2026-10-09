#!/usr/bin/env bash
# Checks that every ValidatingPolicy in Git (platform/kyverno-policies/) is in the Lab
# and Ready: Kyverno compiled it and set up its webhook. And that each has a result in
# the Lab's PolicyReports, since Ready doesn't mean the background scan can match what
# the policy names (#73). Every policy matches something the Lab runs, so one with no
# result can't scan what it names. A new Lab's policies, and its first background scan,
# take a while, so it retries for 2m.
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

# Prints each policy that isn't Ready yet, or has no PolicyReport result yet, and why.
pending_policies() {
  local ready reported policy
  ready=$(kubectl get validatingpolicies \
    -o jsonpath='{range .items[?(@.status.conditionStatus.ready==true)]}{.metadata.name}{"\n"}{end}' 2>&1) || ready=""
  reported=$(kubectl get policyreports,clusterpolicyreports -A \
    -o jsonpath='{range .items[*].results[*]}{.policy}{"\n"}{end}' 2>&1) || reported=""
  for policy in "${policies[@]}"; do
    if ! grep -qxF "$policy" <<<"$ready"; then
      echo "$policy: not Ready"
    elif ! grep -qxF "$policy" <<<"$reported"; then
      echo "$policy: no result in any PolicyReport"
    fi
  done
}

eventually 'policy %s' "${policies[@]}" -- pending_policies

#!/usr/bin/env bash
# Usage: rollouts-login.sh
# Checks the Rollouts dashboard's sign-in from the Host, as a browser on it would use it
# (ADR 0013), with the Lab login's password from the Secret Store: the dashboard sends a
# request without a session to Dex, and a sign-in to Hubble UI, also behind oauth2-proxy,
# opens it too. sso-login checks the rest of single sign-on; this is apart, since a Lab
# may be built without Argo Rollouts.
# Run by rollouts-login, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"
# shellcheck source=sso-browser.sh
source "$(dirname "$0")/sso-browser.sh"

rollouts=https://$PLATFORM_FACT_ROLLOUTS_HOST

expect_sent_to_dex "The Rollouts dashboard" "$rollouts/"
sign_in_to_hubble "$tmp/proxied.jar"
# With the cookie of that sign-in, and no redirect followed. The dashboard's own page:
# it answers / with a redirect there, whoever asks.
status=$(lab_curl -b "$tmp/proxied.jar" -o /dev/null -w '%{http_code}' "$rollouts/rollouts/")
if [[ $status == 200 ]]; then
  ok "The sign-in to Hubble UI opens the Rollouts dashboard too"
else
  fail "The sign-in to Hubble UI doesn't open the Rollouts dashboard: HTTP $status"
fi

exit "$bad"

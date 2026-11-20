#!/usr/bin/env bash
# Usage: grafana-login.sh
# Checks Grafana's sign-in from the Host, as a browser on it would use it (ADR 0013),
# with the Lab login's password from the Secret Store: Grafana signs the Lab login in
# through Dex as an Admin, that sign-in opens Hubble UI too without Dex asking again,
# and Grafana's Break-glass login still works. sso-login checks the rest of single
# sign-on; this is apart, since a Lab may be built without Grafana.
# Run by grafana-login, whose script steps point kubectl at the Lab through a context
# named chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"
# shellcheck source=sso-browser.sh
source "$(dirname "$0")/sso-browser.sh"

grafana=$PLATFORM_FACT_GRAFANA_URL

# Grafana's own OIDC login. Its API takes no token of Dex's, so it's signed in to as a
# browser would, which also shows the role it gives the Lab login.
landed=$(sign_in "$tmp/grafana.jar" "$grafana/login/generic_oauth")
who=$(lab_curl -b "$tmp/grafana.jar" "$grafana/api/user" | jq -r '.email // empty' 2>/dev/null) || who=""
role=$(lab_curl -b "$tmp/grafana.jar" "$grafana/api/user/orgs" | jq -r '.[0].role // empty' 2>/dev/null) || role=""
if [[ $who == "$login" && $role == Admin ]]; then
  ok "Grafana signs the Lab login in through Dex, as an Admin"
else
  fail "Grafana doesn't sign the Lab login in as an Admin: it ends on '${landed%%\?*}', as '${who:-nobody}' with the role '${role:-none}'"
fi

# One sign-in for every UI: Dex remembers the browser that signed in to Grafana. With
# that jar, which has no cookie of oauth2-proxy's, Hubble UI goes through Dex and back
# without the form: nothing here fills it in, so ending on it is a failure.
landed=$(browse "$tmp/grafana.jar" "$hubble/")
if [[ $landed == "200 $hubble/" ]]; then
  ok "The sign-in to Grafana opens Hubble UI too, without Dex asking again"
else
  fail "The sign-in to Grafana doesn't open Hubble UI: it ends on '${landed%%\?*}'"
fi

# The Break-glass login, which needs neither Dex nor oauth2-proxy.
status=$(kubectl -n "$VERIFY_NS_MONITORING" get secret "$PLATFORM_FACT_GRAFANA_ADMIN_SECRET" -o json |
  jq '.data | {"user": (.["admin-user"] | @base64d), "password": (.["admin-password"] | @base64d)}' |
  lab_curl -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$grafana/login")
if [[ $status == 200 ]]; then
  ok "Grafana's Break-glass login works"
else
  fail "Grafana's Break-glass login doesn't work: HTTP $status"
fi

exit "$bad"

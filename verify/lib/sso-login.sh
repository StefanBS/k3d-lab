#!/usr/bin/env bash
# Usage: sso-login.sh
# Checks single sign-on from the Host, as a browser on it would use it (ADR 0013), with
# the Lab login's password from the Secret Store:
#   - Dex serves the signing keys in its storage, so a restart keeps them.
#   - Dex gives the Lab login a token for its password, and refuses a wrong one.
#   - ArgoCD's API takes that token, as its admin.
#   - Hubble UI sends a request without a session to Dex, and the Lab login opens it.
#   - Grafana signs the Lab login in through Dex, as an Admin.
#   - That sign-in opens ArgoCD and Hubble UI too, without Dex asking again.
#   - ArgoCD's and Grafana's Break-glass logins still work.
# rollouts-login.sh checks the Rollouts dashboard, which a Lab may be built without.
# Every request trusts only the Lab CA. verify.sh exports LAB_CA_CERT, and the Platform
# facts and namespaces this reads (scripts/lib/verify-facts.sh). No secret is
# passed as an argument, where the Host's process list would show it: each goes to curl
# on stdin, or from a file in a directory that's deleted afterwards.
# Run by sso-login, whose script steps point kubectl at the Lab through a context named
# chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"
# shellcheck source=../../scripts/lib/sso.sh
source "$(dirname "$0")/../../scripts/lib/sso.sh"
# shellcheck source=sso-browser.sh
source "$(dirname "$0")/sso-browser.sh"

argocd=https://$PLATFORM_FACT_ARGOCD_HOST
grafana=$PLATFORM_FACT_GRAFANA_URL
hubble=https://$PLATFORM_FACT_HUBBLE_HOST

# Usage: token_status <password>
# Asks Dex for a token for the Lab login with that password, through Verify's own
# client, which can only use this grant. Prints the HTTP status, and leaves Dex's answer
# in $tmp/token.
token_status() {
  printf %s "$1" | lab_curl -o "$tmp/token" -w '%{http_code}' "$sso/token" \
    -d grant_type=password -d client_id=verify -d 'scope=openid email' \
    --data-urlencode "username=$login" --data-urlencode password@-
}

# Dex keeps its state in the Lab's API: the signing keys it serves are the ones in its
# storage. With a state of its own it would have made its own keys, and a restart would
# make new ones, which no UI that signed in before trusts. Its keys are one custom
# resource, which Dex names. A request that fails counts as no keys.
served=$(lab_curl "$sso/keys" | jq -c '[.keys[].kid] | sort') || served=""
stored=$(kubectl -n "$VERIFY_NS_SSO" get signingkeies.dex.coreos.com openid-connect-keys -o json \
  | jq -c '[.signingKeyPub.kid, .verificationKeys[]?.publicKey.kid] | map(select(. != null)) | sort') || stored=""
if verdict=$(printf '%s\n%s\n' "$served" "$stored" | sso_keys_stored); then
  ok "Dex serves the $verdict signing keys in its storage"
else
  fail "Dex doesn't serve the signing keys in its storage: $verdict"
fi

# The password grant.
status=$(token_status "$password")
id_token=$(jq -r '.id_token // empty' "$tmp/token" 2>/dev/null) || id_token=""
if [[ $status == 200 && -n $id_token ]]; then
  ok "Dex gives the Lab login a token for its password"
else
  fail "Dex gives the Lab login no token for its password: HTTP $status"
fi
status=$(token_status "not-$password")
# Only a refusal counts: a Dex that's down answers a wrong password with no token too.
if [[ $status == 401 ]] && ! jq -e 'has("id_token")' "$tmp/token" >/dev/null 2>&1; then
  ok "Dex refuses a wrong password"
else
  fail "Dex doesn't refuse a wrong password: HTTP $status"
fi

# ArgoCD takes Dex's token, and maps the Lab login to its admin role: listing
# Applications takes a role, and ArgoCD gives none by default.
printf 'Authorization: Bearer %s\n' "$id_token" >"$tmp/bearer"
status=$(lab_curl -o "$tmp/applications" -w '%{http_code}' -H "@$tmp/bearer" "$argocd/api/v1/applications?fields=items.metadata.name")
if [[ $status == 200 ]] && jq -e '[.items[].metadata.name] | index("root")' "$tmp/applications" >/dev/null 2>&1; then
  ok "ArgoCD's API takes the Lab login's token, and lists the Applications"
else
  fail "ArgoCD's API doesn't list the Applications for the Lab login's token: HTTP $status"
fi

# A UI behind oauth2-proxy.
expect_sent_to_dex "Hubble UI" "$hubble/"
landed=$(sign_in "$tmp/proxied.jar" "$hubble/")
if [[ $landed == "200 $hubble/" ]]; then
  ok "The Lab login opens Hubble UI"
else
  fail "The Lab login doesn't open Hubble UI: it ends on '${landed%%\?*}'"
fi
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
# that jar, ArgoCD's login goes through Dex and back without the form: nothing here
# fills it in, so ending on it is a failure.
landed=$(browse "$tmp/grafana.jar" "$argocd/auth/login")
who=$(lab_curl -b "$tmp/grafana.jar" "$argocd/api/v1/session/userinfo" | jq -r '.username // empty' 2>/dev/null) || who=""
if [[ $landed == "200 $argocd/" && $who == "$login" ]]; then
  ok "The sign-in to Grafana opens ArgoCD too, without Dex asking again"
else
  fail "The sign-in to Grafana doesn't open ArgoCD: its login ends on '${landed%%\?*}', as '${who:-nobody}'"
fi
# The same for a UI behind oauth2-proxy, which this jar has no cookie of.
landed=$(browse "$tmp/grafana.jar" "$hubble/")
if [[ $landed == "200 $hubble/" ]]; then
  ok "The sign-in to Grafana opens Hubble UI too, without Dex asking again"
else
  fail "The sign-in to Grafana doesn't open Hubble UI: it ends on '${landed%%\?*}'"
fi

# The Break-glass logins, which need neither Dex nor oauth2-proxy.
status=$(kubectl -n "$VERIFY_NS_ARGOCD" get secret argocd-initial-admin-secret -o json |
  jq '{"username": "admin", "password": (.data.password | @base64d)}' |
  lab_curl -o "$tmp/session" -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$argocd/api/v1/session")
if [[ $status == 200 ]] && jq -e 'has("token")' "$tmp/session" >/dev/null 2>&1; then
  ok "ArgoCD's Break-glass login works"
else
  fail "ArgoCD's Break-glass login doesn't work: HTTP $status"
fi
status=$(kubectl -n "$VERIFY_NS_MONITORING" get secret "$PLATFORM_FACT_GRAFANA_ADMIN_SECRET" -o json |
  jq '.data | {"user": (.["admin-user"] | @base64d), "password": (.["admin-password"] | @base64d)}' |
  lab_curl -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$grafana/login")
if [[ $status == 200 ]]; then
  ok "Grafana's Break-glass login works"
else
  fail "Grafana's Break-glass login doesn't work: HTTP $status"
fi

exit "$bad"

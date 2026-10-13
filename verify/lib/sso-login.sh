#!/usr/bin/env bash
# Usage: sso-login.sh
# Checks single sign-on from the Host, as a browser on it would use it (ADR 0013), with
# the Lab login's password from the Secret Store:
#   - Dex gives the Lab login a token for its password, and refuses a wrong one.
#   - ArgoCD's API takes that token, as its admin.
#   - The Rollouts dashboard and Hubble UI send a request without a session to Dex, and
#     one sign-in opens both.
#   - Grafana signs the Lab login in through Dex, as an Admin.
#   - ArgoCD's and Grafana's Break-glass logins still work.
# Every request trusts only the Lab CA (verify.sh exports LAB_CA_CERT). No secret is
# passed as an argument, where the Host's process list would show it: each goes to curl
# on stdin, or from a file in a directory that's deleted afterwards.
# Run by sso-login, whose script steps point kubectl at the Lab through a context named
# chainsaw.
set -euo pipefail
# shellcheck source=checks.sh
source "$(dirname "$0")/checks.sh"

sso=https://sso.lab.localhost
argocd=https://argocd.lab.localhost
grafana=https://grafana.lab.localhost
rollouts=https://rollouts.lab.localhost
hubble=https://hubble.lab.localhost
login=lab@lab.localhost

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bad=0
ok() { echo "OK    $1"; }
fail() {
  echo "FAIL  $1"
  bad=1
}

# Usage: lab_curl <curl args>...
# A failed connection is retried: the Gateway drops some while a route changes.
lab_curl() {
  curl -sS --cacert "$LAB_CA_CERT" --retry 5 --retry-delay 2 --retry-connrefused "$@"
}

# Usage: secret_value <namespace> <secret> <key>
# Prints the value, and a newline after it.
secret_value() {
  kubectl -n "$1" get secret "$2" -o json | KEY=$3 yq -p json '.data[strenv(KEY)] | @base64d'
}

# Usage: token <password>
# Asks Dex for a token for the Lab login with that password, through Verify's own
# client, which can only use this grant. Prints the HTTP status, and leaves Dex's answer
# in $tmp/token.
token() {
  printf %s "$1" | lab_curl -o "$tmp/token" -w '%{http_code}' "$sso/token" \
    -d grant_type=password -d client_id=verify -d 'scope=openid email' \
    --data-urlencode "username=$login" --data-urlencode password@-
}

# Usage: sign_in <cookie jar> <url>
# Opens the URL as a browser would, following every redirect and keeping the cookies in
# the jar. If that ends on Dex's login form, fills it in with the Lab login and follows
# the redirects again. Prints the HTTP status and the URL it ended on, and leaves the
# page in $tmp/page.
sign_in() {
  local jar=$1 url=$2 landed
  landed=$(lab_curl -L -b "$jar" -c "$jar" -o "$tmp/page" -w '%{http_code} %{url_effective}' "$url")
  if [[ $landed == "200 $sso/auth/local/login"* ]]; then
    landed=$(printf %s "$password" | lab_curl -L -b "$jar" -c "$jar" -o "$tmp/page" \
      -w '%{http_code} %{url_effective}' "${landed#* }" \
      --data-urlencode "login=$login" --data-urlencode password@-)
  fi
  echo "$landed"
}

# Usage: expect_sent_to_dex <UI's name> <url>
# Without a session, the UI's address answers with a redirect to Dex, not with the page.
expect_sent_to_dex() {
  local got
  got=$(lab_curl -o /dev/null -w '%{http_code} %{redirect_url}' "$2")
  if [[ $got == "302 $sso/"* ]]; then
    ok "$1 sends a request without a session to Dex"
  else
    fail "$1 answers a request without a session with '${got%%\?*}', not a redirect to $sso"
  fi
}

password=$("$(dirname "$0")/../../scripts/secret-store.sh" bao kv get -mount=lab -field=password platform/sso/login </dev/null)

# The password grant.
status=$(token "$password")
id_token=$(jq -r '.id_token // empty' "$tmp/token" 2>/dev/null) || id_token=""
if [[ $status == 200 && -n $id_token ]]; then
  ok "Dex gives the Lab login a token for its password"
else
  fail "Dex gives the Lab login no token for its password: HTTP $status"
fi
status=$(token "not-$password")
if [[ $status != 200 ]] && ! jq -e 'has("id_token")' "$tmp/token" >/dev/null 2>&1; then
  ok "Dex refuses a wrong password (HTTP $status)"
else
  fail "Dex gives a token for a wrong password"
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

# The UIs behind oauth2-proxy.
expect_sent_to_dex "The Rollouts dashboard" "$rollouts/"
expect_sent_to_dex "Hubble UI" "$hubble/"
landed=$(sign_in "$tmp/proxied.jar" "$hubble/")
if [[ $landed == "200 $hubble/" ]]; then
  ok "The Lab login opens Hubble UI"
else
  fail "The Lab login doesn't open Hubble UI: it ends on '${landed%%\?*}'"
fi
# With the cookie of that sign-in, and no redirect followed. The dashboard's own page:
# it answers / with a redirect there, whoever asks.
status=$(lab_curl -b "$tmp/proxied.jar" -o /dev/null -w '%{http_code}' "$rollouts/rollouts/")
if [[ $status == 200 ]]; then
  ok "The sign-in to Hubble UI opens the Rollouts dashboard too"
else
  fail "The sign-in to Hubble UI doesn't open the Rollouts dashboard: HTTP $status"
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

# The Break-glass logins, which need neither Dex nor oauth2-proxy.
status=$(secret_value argocd argocd-initial-admin-secret password |
  jq -Rs '{"username": "admin", "password": rtrimstr("\n")}' |
  lab_curl -o "$tmp/session" -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$argocd/api/v1/session")
if [[ $status == 200 ]] && jq -e 'has("token")' "$tmp/session" >/dev/null 2>&1; then
  ok "ArgoCD's Break-glass login works"
else
  fail "ArgoCD's Break-glass login doesn't work: HTTP $status"
fi
status=$(jq -n --arg user "$(secret_value monitoring grafana-admin admin-user)" \
  --rawfile password <(secret_value monitoring grafana-admin admin-password) \
  '{"user": $user, "password": ($password | rtrimstr("\n"))}' |
  lab_curl -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d @- "$grafana/login")
if [[ $status == 200 ]]; then
  ok "Grafana's Break-glass login works"
else
  fail "Grafana's Break-glass login doesn't work: HTTP $status"
fi

exit "$bad"

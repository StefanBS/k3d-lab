# Sourced, with scripts/lib/sso.sh, by the checks' scripts that sign in from the Host, as a browser on it would
# (ADR 0013): sso-login.sh, rollouts-login.sh and grafana-login.sh. Reads the Lab login's password from the
# Secret Store, and keeps the cookies and answers in $tmp, deleted when the script exits.
# Every request trusts only the Lab CA. verify.sh exports LAB_CA_CERT, and the Platform
# facts this reads (scripts/lib/verify-facts.sh). The script exits "$bad" at its end,
# which fail sets.
# shellcheck shell=bash
# shellcheck disable=SC2034  # bad and hubble are read by the scripts that source this file

# shellcheck source=../../scripts/lib/sso.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/sso.sh"

sso=$PLATFORM_FACT_SSO_URL
login=$PLATFORM_FACT_SSO_LOGIN
# Hubble UI, behind oauth2-proxy, which every Lab has.
hubble=https://$PLATFORM_FACT_HUBBLE_HOST

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

# Usage: browse <cookie jar> <url> [curl args]...
# Opens the URL as a browser would, following every redirect and keeping the cookies in
# the jar. Prints the HTTP status and the URL it ended on.
browse() {
  local jar=$1
  shift
  lab_curl -L -b "$jar" -c "$jar" -o /dev/null -w '%{http_code} %{url_effective}' "$@"
}

# Usage: sign_in <cookie jar> <url>
# Browses to the URL. If that ends on Dex's login form, fills it in with the Lab login
# and follows the redirects again. Prints the HTTP status and the URL it ended on.
sign_in() {
  local jar=$1 url=$2 landed
  landed=$(browse "$jar" "$url")
  if [[ $landed == "200 $sso/auth/local/login"* ]]; then
    landed=$(printf %s "$password" |
      browse "$jar" "${landed#* }" --data-urlencode "login=$login" --data-urlencode password@-)
  fi
  echo "$landed"
}

# Usage: sign_in_to_hubble <cookie jar>
# Signs in to Hubble UI with the Lab login, keeping oauth2-proxy's cookie in the jar.
sign_in_to_hubble() {
  local landed
  landed=$(sign_in "$1" "$hubble/")
  if [[ $landed == "200 $hubble/" ]]; then
    ok "The Lab login opens Hubble UI"
  else
    fail "The Lab login doesn't open Hubble UI: it ends on '${landed%%\?*}'"
  fi
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

password=$("$(dirname "${BASH_SOURCE[0]}")/../../scripts/secret-store.sh" bao kv get -mount=lab -field=password "$SSO_LOGIN_SECRET" </dev/null)

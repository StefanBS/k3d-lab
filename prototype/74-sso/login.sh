#!/usr/bin/env bash
# PROTOTYPE (#74): logs in as a browser would, with curl and a cookie jar, and prints
# every hop. Usage: login.sh <url> [<jar>]   (an existing jar is reused: one sign-in)
source "$(dirname "$0")/../../scripts/lib.sh"
source "$LAB_ROOT/scripts/host.sh"
source "$LAB_ROOT/scripts/secret-store.sh"
url=$1 jar=${2:-$(mktemp)}
hops() { curl -s -L -o "$body" -b "$jar" -c "$jar" -w '%{http_code} %{url_effective}\n' "$@"; }
body=$(mktemp)
# Follows the redirects to Dex's login form, or straight to the page when the jar
# already holds a session.
landed=$(hops "$url")
echo "GET  $url -> $landed"
if [[ $landed == *sso.lab.localhost/auth/local/login* ]]; then
  password=$(secret_store_bao kv get -mount=lab -field=password platform/sso/login)
  landed=$(hops "${landed#* }" --data-urlencode login=lab@lab.localhost --data-urlencode "password=$password")
  echo "POST login -> $landed"
fi
head -c 200 "$body" | tr '\n' ' '
echo

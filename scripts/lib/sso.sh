# Which secrets single sign-on keeps in the Secret Store (ADR 0013), which of them it
# still lacks, and whether Dex serves the signing keys in its storage. Sourced by
# secret-store.sh and verify/lib/sso-login.sh, and on its own by scripts/tests/, so it
# sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# sso_secret_clients: reads Dex's config (platform/dex/config.yaml) on stdin, and prints
# the id of each static client that needs a secret in the Secret Store, one per line.
sso_secret_clients() {
  yq '.staticClients[] | select(has("secretEnv")) | .id'
}

# The OIDC client whose secret in the Secret Store also holds a cookie secret: oauth2-proxy
# signs its session cookie with it (platform/oauth2-proxy/).
SSO_COOKIE_CLIENT=oauth2-proxy

# sso_secrets: reads Dex's config on stdin, and prints every secret that single sign-on
# keeps in the Secret Store, as "<path under lab/> <field>...", one per line: the Lab
# login's, then each client's. Prints nothing if it can't read the clients.
sso_secrets() {
  local clients client
  clients=$(sso_secret_clients) || return
  echo "platform/sso/login password"
  for client in $clients; do
    if [[ $client == "$SSO_COOKIE_CLIENT" ]]; then
      echo "platform/sso/clients/$client secret cookie"
    else
      echo "platform/sso/clients/$client secret"
    fi
  done
}

# sso_secret_answer <status>: reads what `bao kv get -format=json` printed on stdin,
# errors included, given the status it exited with. Prints the secret, or nothing when
# the Secret Store says it has none there. Fails on any other answer, such as a Secret
# Store that's sealed: that must not read as "none".
sso_secret_answer() {
  local status=$1 answer
  answer=$(cat)
  if ((status == 0)); then
    printf '%s\n' "$answer"
  elif [[ $answer != *"No value found"* ]]; then
    printf '%s\n' "$answer" >&2
    return 1
  fi
}

# sso_missing_fields <field>...: reads a secret on stdin, as `bao kv get -format=json`
# prints it, or nothing when the Secret Store has none there. Prints each of the fields
# that it lacks, or holds empty.
sso_missing_fields() {
  # shellcheck disable=SC2016 # $have is jq's, not the shell's.
  jq -rn '([inputs][0].data.data // {}) as $have | $ARGS.positional[] | select(($have[.] // "") == "")' --args "$@"
}

# sso_secret_version: reads a secret on stdin, as sso_missing_fields does, and prints its
# version: 0 when the Secret Store has none there, which is what a write that must not
# replace anything checks for.
sso_secret_version() {
  jq -rn '[inputs][0].data.metadata.version // 0'
}

# sso_keys_stored: reads two lines: the ids of the signing keys Dex serves, then the ids
# of those in its storage, each as a sorted JSON array, or an empty line if there were
# none. Prints how many keys there are, if Dex serves exactly the stored ones: a Dex with
# a state of its own would have made its own, and lost them with each restart. Otherwise
# prints what is wrong, and fails.
sso_keys_stored() {
  local verdict
  verdict=$(jq -Rrs '
    (split("\n") | if .[-1] == "" then .[:-1] else . end) as $answers
    | ($answers[0] // "") as $served
    | ($answers[1] // "") as $stored
    | if ($served | test("^\\[\"") | not) then "Dex serves no signing keys"
      elif ($stored | test("^\\[\"") | not) then "Dex'"'"'s storage holds no signing keys"
      elif $served != $stored then "Dex serves \($served), not the keys in its storage, \($stored)"
      else $served | fromjson | length end')
  echo "$verdict"
  [[ $verdict =~ ^[0-9]+$ ]]
}

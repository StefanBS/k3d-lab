# Which OIDC clients keep a secret in the Secret Store (ADR 0013). Sourced by
# secret-store.sh, and on its own by scripts/tests/, so it sets no shell options and runs
# nothing when sourced.
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

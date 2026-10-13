#!/usr/bin/env bats
# Which OIDC clients need a secret in the Secret Store (scripts/sso-state.sh), from Dex's
# config, without a Lab or a Secret Store.

setup() {
  # shellcheck source=../sso-state.sh
  source "$BATS_TEST_DIRNAME/../sso-state.sh"
}

@test "a client with secretEnv needs a secret" {
  run sso_secret_clients <<'EOF'
staticClients:
  - id: argocd
    secretEnv: ARGOCD_CLIENT_SECRET
    redirectURIs: [https://argocd.lab.localhost/auth/callback]
EOF
  [[ $status -eq 0 && $output == argocd ]]
}

@test "a public client, such as Verify's, needs none" {
  run sso_secret_clients <<'EOF'
staticClients:
  - id: grafana
    secretEnv: GRAFANA_CLIENT_SECRET
  - id: verify
    public: true
EOF
  [[ $status -eq 0 && $output == grafana ]]
}

@test "every client that needs one is printed, in the config's order" {
  run sso_secret_clients <<'EOT'
staticClients:
  - id: oauth2-proxy
    secretEnv: OAUTH2_PROXY_CLIENT_SECRET
  - id: argocd
    secretEnv: ARGOCD_CLIENT_SECRET
  - id: verify
    public: true
  - id: grafana
    secretEnv: GRAFANA_CLIENT_SECRET
EOT
  [[ $status -eq 0 && $output == $'oauth2-proxy\nargocd\ngrafana' ]]
}

@test "a config without clients: none, and no failure" {
  run sso_secret_clients <<<"issuer: https://sso.lab.localhost"
  [[ $status -eq 0 && -z $output ]]
}

@test "a config that isn't YAML: fails, rather than saying no client needs a secret" {
  run sso_secret_clients <<<"staticClients: [{id: argocd"
  [[ $status -ne 0 ]]
}

@test "the secrets single sign-on keeps: the Lab login, and each client's, oauth2-proxy's with its cookie secret" {
  run sso_secrets <<'EOT'
staticClients:
  - id: oauth2-proxy
    secretEnv: OAUTH2_PROXY_CLIENT_SECRET
  - id: argocd
    secretEnv: ARGOCD_CLIENT_SECRET
  - id: verify
    public: true
EOT
  [[ $status -eq 0 ]]
  [[ $output == "platform/sso/login password
platform/sso/clients/oauth2-proxy secret cookie
platform/sso/clients/argocd secret" ]]
}

@test "a config that isn't YAML: no secrets at all, and fails" {
  run sso_secrets <<<"staticClients: [{id: argocd"
  [[ $status -ne 0 && $output != *platform/sso/login* ]]
}

# secret <version> <data>: a secret as `bao kv get -format=json` prints it.
secret() {
  jq -n --argjson v "$1" --argjson d "$2" '{"data": {"data": $d, "metadata": {"version": $v}}}'
}

@test "a secret the Secret Store doesn't have lacks every field, and has no version" {
  run sso_missing_fields secret cookie <<<""
  [[ $status -eq 0 && $output == $'secret\ncookie' ]]
  run sso_secret_version <<<""
  [[ $status -eq 0 && $output == 0 ]]
}

@test "a secret with every field lacks none" {
  run sso_missing_fields secret cookie <<<"$(secret 1 '{"secret": "a", "cookie": "b"}')"
  [[ $status -eq 0 && -z $output ]]
}

@test "a secret lacks the fields it doesn't have, or holds empty" {
  run sso_missing_fields secret cookie <<<"$(secret 3 '{"secret": "a"}')"
  [[ $status -eq 0 && $output == cookie ]]
  run sso_missing_fields secret cookie <<<"$(secret 3 '{"secret": "", "cookie": "b"}')"
  [[ $status -eq 0 && $output == secret ]]
  run sso_secret_version <<<"$(secret 3 '{"secret": "a"}')"
  [[ $status -eq 0 && $output == 3 ]]
}

@test "an answer that isn't a secret, such as an error: fails, rather than saying what it lacks" {
  run sso_missing_fields secret <<<"Error making API request."
  [[ $status -ne 0 ]]
  run sso_secret_version <<<"Error making API request."
  [[ $status -ne 0 ]]
}

@test "bao found the secret: its answer is the secret" {
  run sso_secret_answer 0 <<<"$(secret 1 '{"secret": "a"}')"
  [[ $status -eq 0 && $(jq -r .data.data.secret <<<"$output") == a ]]
}

@test "bao says there's no secret there: nothing, and no failure" {
  run sso_secret_answer 2 <<<"No value found at lab/data/platform/sso/login"
  [[ $status -eq 0 && -z $output ]]
}

@test "bao fails for any other reason, such as a sealed Secret Store: fails, rather than saying there's none" {
  run sso_secret_answer 2 <<<"Error making API request. Code: 503. Errors: * Vault is sealed"
  [[ $status -ne 0 ]]
}

#!/usr/bin/env bats
# How the Secret Store trusts the Lab (scripts/lib/secret-store.sh), without a Lab or a
# Secret Store: bao stands in for both, and the values are ESO's own, in a copy of the
# repo the tests change.

setup() {
  load lab
  for module in host secret-store platform-facts components; do
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib/$module.sh"
  done
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  mkdir -p "$LAB_ROOT/platform"
  cp -r "$BATS_TEST_DIRNAME/../../platform/external-secrets" "$LAB_ROOT/platform/"
  # Defined after the modules, which would replace them. With no root token, the real
  # secret_store_bao would give up rather than reach the Host's Secret Store.
  SECRET_STORE_INIT=$BATS_TEST_TMPDIR/no-init.json
  BAO_CALLS=$BATS_TEST_TMPDIR/bao-calls
  # bao logs each call's arguments to BAO_CALLS, one line each, and has Kubernetes auth
  # enabled already.
  secret_store_bao() { printf '%s\n' "$*" >>"$BAO_CALLS"; }
  bao_enabled() { :; }
  lab_server_ip() { echo 172.28.0.2; }
  lab_ca_configmap() { :; }
}

# role_binding <role>: the ServiceAccount and namespace the Secret Store binds that role to.
role_binding() {
  grep "^write auth/kubernetes/role/$1 " "$BAO_CALLS" | grep -o 'bound_service_account_[a-z]*=[^ ]*'
}

# rename_service_account <role> <name>: the ClusterSecretStore that logs in as that role
# names the ServiceAccount <name> instead.
rename_service_account() {
  local values=$LAB_ROOT/platform/external-secrets/values.yaml
  ROLE=$1 NAME=$2 yq -i '.extraObjects[] |= (from_yaml
    | (select(.kind == "ClusterSecretStore" and .spec.provider.vault.auth.kubernetes.role == strenv(ROLE))
      | .spec.provider.vault.auth.kubernetes.serviceAccountRef.name) = strenv(NAME)
    | to_yaml)' "$values"
}

@test "each role: bound to the ServiceAccount its ClusterSecretStore names, in ESO's namespace" {
  run secret_store_trust_lab
  [[ $status -eq 0 ]]
  [[ $(role_binding eso) == "bound_service_account_names=external-secrets
bound_service_account_namespaces=external-secrets" ]]
  [[ $(role_binding eso-platform) == "bound_service_account_names=external-secrets-platform
bound_service_account_namespaces=external-secrets" ]]
}

@test "a ClusterSecretStore that names another ServiceAccount: its role follows" {
  rename_service_account eso-platform platform-reader
  run secret_store_trust_lab
  [[ $status -eq 0 ]]
  [[ $(role_binding eso-platform) == "bound_service_account_names=platform-reader
bound_service_account_namespaces=external-secrets" ]]
}

@test "no ClusterSecretStore logs in as a role: fails, saying which fact" {
  yq -i '.extraObjects[0] |= (from_yaml
    | .spec.provider.vault.auth.kubernetes.role = "eso-workloads" | to_yaml)' \
    "$LAB_ROOT/platform/external-secrets/values.yaml"
  run secret_store_trust_lab
  [[ $status -eq 1 ]]
  [[ $output == *"Platform fact 'eso.service-account' doesn't resolve"* ]]
}

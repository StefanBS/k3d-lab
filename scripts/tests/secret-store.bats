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
  # With no root token, the real secret_store_bao would give up rather than reach the
  # Host's Secret Store.
  SECRET_STORE_INIT=$BATS_TEST_TMPDIR/no-init.json
  BAO_CALLS=$BATS_TEST_TMPDIR/bao-calls
  # Defined after the modules, which would replace them. bao logs each call's arguments
  # to BAO_CALLS, one line each, and has Kubernetes auth enabled already.
  secret_store_bao() { printf '%s\n' "$*" >>"$BAO_CALLS"; }
  bao_enabled() { :; }
  lab_server_ip() { echo 172.28.0.2; }
  lab_ca_configmap() { :; }
}

# role_binding <role>: the ServiceAccount and namespace the Secret Store binds that role to.
role_binding() {
  grep "^write auth/kubernetes/role/$1 " "$BAO_CALLS" | grep -o 'bound_service_account_[a-z]*=[^ ]*'
}

# change_store <role> <field> <value>: in the ClusterSecretStore that logs in as that
# role, sets that field of its Kubernetes auth, such as serviceAccountRef.name.
change_store() {
  ROLE=$1 VALUE=$3 yq -i ".extraObjects[] |= (from_yaml
    | (select(.kind == \"ClusterSecretStore\" and .spec.provider.vault.auth.kubernetes.role == strenv(ROLE))
      | .spec.provider.vault.auth.kubernetes.$2) = strenv(VALUE)
    | to_yaml)" "$LAB_ROOT/platform/external-secrets/values.yaml"
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
  change_store eso-platform serviceAccountRef.name platform-reader
  run secret_store_trust_lab
  [[ $status -eq 0 ]]
  [[ $(role_binding eso-platform) == "bound_service_account_names=platform-reader
bound_service_account_namespaces=external-secrets" ]]
}

@test "no ClusterSecretStore logs in as a role: fails, saying which fact" {
  change_store eso role eso-workloads
  run secret_store_trust_lab
  [[ $status -eq 1 ]]
  [[ $output == *"Platform fact 'eso.service-account' doesn't resolve"* ]]
}

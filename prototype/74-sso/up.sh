#!/usr/bin/env bash
# PROTOTYPE (#74), throwaway: puts single sign-on on a running Lab by hand, one step at
# a time, to answer the five questions in README.md. down.sh takes it all back.
# Usage: up.sh <step>...   steps, in order: store crds secrets dex dns proxy route argocd grafana
source "$(dirname "$0")/../../scripts/lib.sh"
source "$LAB_ROOT/scripts/host.sh"
source "$LAB_ROOT/scripts/secret-store.sh"
here=$LAB_ROOT/prototype/74-sso/manifests

# What `just host setup` and `just up` would do: the login and each client's secret,
# made once, and a role that reads lab/platform/* alone.
store() {
  local path
  put_once() { # <path> <field>...
    path=$1
    shift
    secret_store_bao kv get -mount=lab "$path" >/dev/null 2>&1 && return
    local args=() field
    for field in "$@"; do args+=("$field=$(openssl rand -hex 16)"); done
    quietly secret_store_bao kv put -mount=lab "$path" "${args[@]}"
  }
  put_once platform/sso/login password
  put_once platform/sso/clients/oauth2-proxy secret cookie
  put_once platform/sso/clients/argocd secret
  put_once platform/sso/clients/grafana secret
  quietly secret_store_bao policy write eso-platform - <<'EOF'
path "lab/data/platform/*" { capabilities = ["read"] }
path "lab/metadata/platform/*" { capabilities = ["read", "list"] }
EOF
  quietly secret_store_bao write auth/kubernetes/role/eso-platform \
    bound_service_account_names=external-secrets-platform \
    bound_service_account_namespaces=external-secrets \
    audience="$(platform_fact eso.audience)" token_policies=eso-platform token_ttl=1h
}

# The experimental channel, which has the ExternalAuth filter. gateway-api is paused so
# ArgoCD doesn't put the standard channel back. k3s installs the standard channel
# itself (its gateway-api-crd addon), with a ValidatingAdmissionPolicy that refuses the
# experimental channel on top of it; its own message says to remove it first. The
# bundle brings the policy back, and it then lets experimental CRDs be updated.
crds() {
  local bundle=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml
  "$LAB_ROOT/scripts/pause.sh" pause gateway-api
  kc delete validatingadmissionpolicybinding,validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found
  kc apply --server-side --force-conflicts -f "$bundle"
}

secrets() {
  kc create namespace sso --dry-run=client -o yaml | kc apply -f -
  # The Lab CA, for oauth2-proxy to trust Dex's certificate.
  kc -n sso create configmap lab-ca --from-file=ca.crt="$LAB_CA_CERT" --dry-run=client -o yaml | kc apply -f -
  kc apply -f "$here/10-secrets.yaml"
}
dex() { kc apply -f "$here/20-dex.yaml"; }
dns() { kc apply -f "$here/30-coredns-custom.yaml"; }
proxy() { kc apply -f "$here/40-oauth2-proxy.yaml"; }
route() {
  "$LAB_ROOT/scripts/pause.sh" pause hubble
  kc apply --server-side --force-conflicts -f "$here/50-hubble-route.yaml"
}


# Point 4. By hand what platform/argocd/values.yaml and platform/grafana/values.yaml
# would say; both Applications are paused so the changes stay.
lab_ca_configmap() { # <namespace>
  kc -n "$1" create configmap lab-ca --from-file=ca.crt="$LAB_CA_CERT" --dry-run=client -o yaml | kc apply -f -
}
argocd() {
  "$LAB_ROOT/scripts/pause.sh" pause argocd
  lab_ca_configmap argocd
  kc apply -f "$here/60-clients.yaml"
  kc -n argocd patch configmap argocd-cm --type merge -p "$(jq -n '{data: {"oidc.config": "name: Lab\nissuer: https://sso.lab.localhost\nclientID: argocd\nclientSecret: $argocd-sso:clientSecret\nrequestedScopes: [openid, profile, email]\n# Verify logs in with its own client.\nallowedAudiences: [argocd, verify]\n"}}')"
  # Dex gives a static user no groups, so the role is mapped by email.
  kc -n argocd patch configmap argocd-rbac-cm --type merge \
    -p '{"data": {"scopes": "[email]", "policy.csv": "g, lab@lab.localhost, role:admin\n"}}'
  # Go reads every file in /etc/ssl/certs, so the Lab CA is trusted beside the public CAs.
  kc -n argocd patch deployment argocd-server --type strategic -p '{"spec": {"template": {"spec": {
    "volumes": [{"name": "lab-ca", "configMap": {"name": "lab-ca"}}],
    "containers": [{"name": "server", "volumeMounts": [
      {"name": "lab-ca", "mountPath": "/etc/ssl/certs/lab-ca.crt", "subPath": "ca.crt"}]}]}}}}'
  kc -n argocd rollout status deployment argocd-server --timeout=180s
}
grafana() {
  "$LAB_ROOT/scripts/pause.sh" pause grafana
  lab_ca_configmap monitoring
  kc apply -f "$here/60-clients.yaml"
  kc -n monitoring patch deployment grafana --type strategic --patch-file "$here/70-grafana-patch.yaml"
  kc -n monitoring rollout status deployment grafana --timeout=180s
}

for step in "$@"; do
  log "Step: $step"
  "$step"
done

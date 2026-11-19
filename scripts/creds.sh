#!/usr/bin/env bash
# Prints the Lab login, which opens every UI and stays the same across Labs (ADR 0013),
# then each UI with its Break-glass login, if it has one: those are new with every Lab.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/host.sh
source "$(dirname "$0")/lib/host.sh"
# shellcheck source=lib/secret-store.sh
source "$(dirname "$0")/lib/secret-store.sh"

need_root_application

argocd_url=https://$(platform_fact argocd.host)
grafana_url=$(platform_fact grafana.url)
grafana_ns=$(component_namespace platform/grafana)
grafana_secret=$(platform_fact grafana.admin-secret)
rollouts_url=https://$(platform_fact rollouts.host)
hubble_url=https://$(platform_fact hubble.host)

# `just host setup` generated it, once.
lab_password=$(secret_store_bao kv get -mount=lab -field=password "$SSO_LOGIN_SECRET" </dev/null)
# The Break-glass logins. ArgoCD generates its own at install, and keeps it in this Secret.
argocd_password=$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
# The root Application says which Features the Lab was built without.
left_out=$(root_application_without)
# Usage: has_feature_of <group>/<name>: whether the Lab has the component's Feature.
has_feature_of() { ! grep -qxF -- "$(component_feature "$1")" <<<"$left_out"; }

echo "The Lab login, which opens every UI below:"
printf '  %-17s %s\n' USER PASSWORD "$(platform_fact sso.login)" "$lab_password"
echo
# The Rollouts dashboard and Hubble UI have no login of their own, so no Break-glass
# login either: only the Lab login opens them.
echo "Each UI, with its Break-glass login, for when the Lab login can't be used:"
uis=(ArgoCD "$argocd_url" admin "$argocd_password")
# Grafana and the Rollouts dashboard are only in a Lab with their Features.
if has_feature_of platform/grafana; then
  # ESO generates Grafana's.
  grafana_login=$(kc -n "$grafana_ns" get secret "$grafana_secret" -o json)
  uis+=(Grafana "$grafana_url"
    "$(yq -p json '.data["admin-user"] | @base64d' <<<"$grafana_login")"
    "$(yq -p json '.data["admin-password"] | @base64d' <<<"$grafana_login")")
fi
if has_feature_of platform/argo-rollouts; then uis+=(Rollouts "$rollouts_url" - -); fi
uis+=(Hubble "$hubble_url" - -)
printf '  %-9s %-31s %-6s %s\n' UI URL USER PASSWORD "${uis[@]}"

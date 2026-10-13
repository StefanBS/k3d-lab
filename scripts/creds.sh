#!/usr/bin/env bash
# Prints the Lab login, which opens every UI and stays the same across Labs (ADR 0013),
# then each UI with its Break-glass login, if it has one: those are new with every Lab.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"
# shellcheck source=secret-store.sh
source "$(dirname "$0")/secret-store.sh"

lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"

argocd_url=https://$(platform_fact argocd.host)
grafana_url=$(platform_fact grafana.url)
grafana_ns=$(component_namespace platform/grafana)
grafana_secret=$(platform_fact grafana.admin-secret)
rollouts_url=https://$(platform_fact rollouts.host)
hubble_url=https://$(platform_fact hubble.host)

# `just host setup` generated it, once.
lab_password=$(secret_store_bao kv get -mount=lab -field=password platform/sso/login </dev/null)
# The Break-glass logins. ArgoCD generates its own at install, and keeps it in this Secret.
argocd_password=$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
# `just up` generates Grafana's.
grafana_login=$(kc -n "$grafana_ns" get secret "$grafana_secret" -o json)
grafana_user=$(yq -p json '.data["admin-user"] | @base64d' <<<"$grafana_login")
grafana_password=$(yq -p json '.data["admin-password"] | @base64d' <<<"$grafana_login")

echo "The Lab login, which opens every UI below:"
printf '  %-17s %s\n' USER PASSWORD "$(platform_fact sso.login)" "$lab_password"
echo
# The Rollouts dashboard and Hubble UI have no login of their own, so no Break-glass
# login either: only the Lab login opens them.
echo "Each UI, with its Break-glass login, for when the Lab login can't be used:"
printf '  %-9s %-31s %-6s %s\n' \
  UI URL USER PASSWORD \
  ArgoCD "$argocd_url" admin "$argocd_password" \
  Grafana "$grafana_url" "$grafana_user" "$grafana_password" \
  Rollouts "$rollouts_url" - - \
  Hubble "$hubble_url" - -

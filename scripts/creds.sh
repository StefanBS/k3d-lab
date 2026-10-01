#!/usr/bin/env bash
# Prints each of the Lab's UIs with its login. The passwords are new with every Lab.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"

argocd_url=https://$(yq '.global.domain' "$LAB_ROOT/platform/argocd/values.yaml")
grafana_url=$(yq '.["grafana.ini"].server.root_url' "$LAB_ROOT/platform/grafana/values.yaml")
grafana_ns=$(yq '.namespace' "$LAB_ROOT/platform/grafana/component.yaml")
grafana_secret=$(yq '.admin.existingSecret' "$LAB_ROOT/platform/grafana/values.yaml")
rollouts_url=https://$(yq '.dashboard.httproute.hostnames[0]' "$LAB_ROOT/platform/argo-rollouts/values.yaml")

# ArgoCD generates its admin password at install and keeps it in this Secret.
argocd_password=$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
# `just up` generates Grafana's.
grafana_login=$(kc -n "$grafana_ns" get secret "$grafana_secret" -o json)
grafana_user=$(yq -p json '.data["admin-user"] | @base64d' <<<"$grafana_login")
grafana_password=$(yq -p json '.data["admin-password"] | @base64d' <<<"$grafana_login")

# The Rollouts dashboard has no login.
printf '%-9s %-31s %-6s %s\n' \
  UI URL USER PASSWORD \
  ArgoCD "$argocd_url" admin "$argocd_password" \
  Grafana "$grafana_url" "$grafana_user" "$grafana_password" \
  Rollouts "$rollouts_url" - -

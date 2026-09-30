#!/usr/bin/env bash
# Prints each of the Lab's UIs with its login. The passwords are new with every Lab.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"

argocd_url=https://$(yq '.global.domain' "$LAB_ROOT/platform/argocd/values.yaml")

# ArgoCD generates its admin password at install and keeps it in this Secret.
argocd_password=$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

printf '%-8s %-30s %-6s %s\n' \
  UI URL USER PASSWORD \
  ArgoCD "$argocd_url" admin "$argocd_password"

#!/usr/bin/env bash
# PROTOTYPE (#74), throwaway: takes back everything up.sh did, in the Lab and in the
# Secret Store, and lets ArgoCD put Git back.
source "$(dirname "$0")/../../scripts/lib.sh"
source "$LAB_ROOT/scripts/host.sh"
source "$LAB_ROOT/scripts/secret-store.sh"
here=$LAB_ROOT/prototype/74-sso/manifests

# The routes and settings first: the standard channel can't hold an ExternalAuth filter.
for application in hubble grafana argocd; do
  "$LAB_ROOT/scripts/pause.sh" resume "$application"
done
kc delete --ignore-not-found -f "$here/60-clients.yaml" -f "$here/30-coredns-custom.yaml"
kc -n argocd delete configmap lab-ca --ignore-not-found
kc -n monitoring delete configmap lab-ca --ignore-not-found
kc delete namespace sso --ignore-not-found
kc delete clustersecretstore secret-store-platform --ignore-not-found
kc delete clusterrolebinding external-secrets-platform-auth-delegator --ignore-not-found
kc -n external-secrets delete serviceaccount external-secrets-platform --ignore-not-found

# The standard channel again, which the safe-upgrades policy allows over experimental.
"$LAB_ROOT/scripts/pause.sh" resume gateway-api
kc delete crd --ignore-not-found xbackends.gateway.networking.x-k8s.io \
  xbackendtrafficpolicies.gateway.networking.x-k8s.io xmeshes.gateway.networking.x-k8s.io

for path in login clients/oauth2-proxy clients/argocd clients/grafana; do
  quietly secret_store_bao kv metadata delete -mount=lab "platform/sso/$path"
done
quietly secret_store_bao delete auth/kubernetes/role/eso-platform
quietly secret_store_bao policy delete eso-platform
log "The Lab and the Secret Store are as they were"

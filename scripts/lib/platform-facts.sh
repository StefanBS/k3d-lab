# Platform facts: what the scripts, and verify's checks, need from the values of the
# Platform and the Workloads, read by name. Sourced by lib.sh, and on its own by
# scripts/tests/, so it sets no shell options and runs nothing when sourced. Every path
# is under LAB_ROOT.
# shellcheck shell=bash

# Each fact's file, and the yq expression that reads it there. Callers ask by name, so
# only this table knows how the values files are laid out, and lint checks that every
# fact still resolves (platform_facts_problems).
declare -gA PLATFORM_FACTS=(
  [argocd.host]='platform/argocd/values.yaml|.global.domain'
  [grafana.url]='platform/grafana/values.yaml|.["grafana.ini"].server.root_url'
  # The Secret ESO generates Grafana's Break-glass login into.
  [grafana.admin-secret]='platform/grafana/values.yaml|.admin.existingSecret'
  [rollouts.host]='platform/argo-rollouts/values.yaml|.dashboard.httproute.hostnames[0]'
  [hubble.host]='platform/hubble/hubble.yaml|select(.kind == "HTTPRoute") | .spec.hostnames[0]'
  # Where the UIs send a browser to sign in: Dex's issuer.
  [sso.url]='platform/dex/config.yaml|.issuer'
  # The Lab login, which signs in by its email.
  [sso.login]='platform/dex/config.yaml|.staticPasswords[0].email'
  # What pods resolve Dex's name to: the Server, where the Gateway listens.
  [sso.server-ip]='platform/coredns-custom/coredns-custom.yaml|.data["sso.override"] | capture("IN A (?P<ip>[0-9.]+)") | .ip'
  # The audience of the tokens ESO logs in to the Secret Store with.
  [eso.audience]='platform/external-secrets/values.yaml|.extraObjects[0] | from_yaml | .spec.provider.vault.auth.kubernetes.serviceAccountRef.audiences[0]'
  # The ServiceAccount each of the Secret Store's roles is bound to: the one the
  # ClusterSecretStore that logs in as that role names.
  [eso.service-account]='platform/external-secrets/values.yaml|.extraObjects[] | from_yaml | .spec.provider.vault.auth.kubernetes | select(.role == "eso") | .serviceAccountRef.name'
  [eso-platform.service-account]='platform/external-secrets/values.yaml|.extraObjects[] | from_yaml | .spec.provider.vault.auth.kubernetes | select(.role == "eso-platform") | .serviceAccountRef.name'
  # Where ESO reaches the Secret Store: the Lab network's gateway.
  [eso.gateway-ip]='platform/external-secrets/values.yaml|.hostAliases[] | select(.hostnames[] == "host.k3d.internal") | .ip'
  # Where Cilium reaches the Kubernetes API, before it can resolve anything.
  [cilium.server-ip]='platform/cilium/values.yaml|.k8sServiceHost'
  [comfyui.host]='workloads/comfyui/comfyui.yaml|select(.kind == "HTTPRoute") | .spec.hostnames[0]'
  [rollouts-demo.host]='workloads/rollouts-demo/rollout.yaml|select(.kind == "HTTPRoute") | .spec.hostnames[0]'
)
# The facts that Git can't read from here, so they repeat a constant of lib/lab.sh: each
# fact's constant, by name. lint checks they match.
declare -gA PLATFORM_PINNED_FACTS=(
  [eso.gateway-ip]=LAB_GATEWAY
  [cilium.server-ip]=LAB_SERVER_IP
  [sso.server-ip]=LAB_SERVER_IP
)

# platform_fact <name>: prints that fact. Fails if there's no such fact, or if it
# doesn't resolve.
platform_fact() {
  local value
  value=$(_platform_fact "$1") || die "$value"
  printf '%s\n' "$value"
}

# platform_facts_problems: prints each fact that doesn't resolve, and each pinned one
# that isn't its constant, one per line, or nothing.
platform_facts_problems() {
  local name value constant
  for name in $(printf '%s\n' "${!PLATFORM_FACTS[@]}" | sort); do
    if ! value=$(_platform_fact "$name"); then
      echo "$value"
    elif [[ -n ${PLATFORM_PINNED_FACTS[$name]:-} ]]; then
      constant=${PLATFORM_PINNED_FACTS[$name]}
      [[ $value == "${!constant}" ]] || echo "Platform fact '$name' is '$value', not $constant (${!constant})"
    fi
  done
}

# _platform_fact <name>: prints that fact, or why there's none, and then fails.
_platform_fact() {
  local fact=${PLATFORM_FACTS[$1]:-} value
  if [[ -z $fact ]]; then
    echo "no Platform fact named '$1'"
    return 1
  fi
  # -e: fails when the expression finds nothing, or null, which it still prints.
  if ! value=$(yq -e "${fact#*|}" "$LAB_ROOT/${fact%%|*}" 2>/dev/null); then
    echo "Platform fact '$1' doesn't resolve: no ${fact#*|} in ${fact%%|*}"
    return 1
  fi
  printf '%s\n' "$value"
}

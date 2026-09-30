#!/usr/bin/env bash
# Checks that the Host has what the Lab needs. Installs nothing; prints hints instead.

# Saved before lib.sh pins DOCKER_HOST to Docker CE: the Podman check below needs the
# caller's own value.
caller_docker_host=${DOCKER_HOST:-}
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# The variable names a .env-style file assigns, sorted.
env_keys() {
  sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$1" | sort
}

# mise installs every tool the Lab needs except Docker CE (mise.toml).
if ! command -v mise >/dev/null; then
  fail "mise is missing: https://mise.jdx.dev/installing-mise.html, then activate it in your shell"
elif [[ $(cd "$LAB_ROOT" && mise trust --show) == *untrusted* ]]; then
  # mise silently ignores a mise.toml it doesn't trust.
  fail "mise doesn't trust this repo's mise.toml yet: run 'mise trust' here"
elif missing=$(cd "$LAB_ROOT" && mise ls --current --missing) && [[ -n $missing ]]; then
  fail "mise hasn't installed $(awk '{ print $1 }' <<<"$missing" | paste -sd' '): run 'mise install' here"
else
  ok "mise has installed every tool in mise.toml"
fi

if engine=$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null) && [[ $engine == Docker* ]]; then
  ok "Docker CE is running ($DOCKER_HOST)"
else
  fail "Docker CE isn't reachable at $DOCKER_HOST (ADR 0001): https://docs.docker.com/engine/install/fedora/"
fi

# Where a plain `docker` in the caller's shell goes: DOCKER_HOST wins over the current context.
caller_endpoint=$caller_docker_host
if [[ -z $caller_endpoint ]]; then
  caller_context=$(env -u DOCKER_HOST docker context show 2>/dev/null) || caller_context=""
  caller_endpoint=$(env -u DOCKER_HOST docker context inspect "$caller_context" \
    --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || caller_endpoint=""
fi
if [[ $caller_endpoint == *podman* ]]; then
  warn "plain 'docker' in your shell goes to Podman ($caller_endpoint); the Lab's recipes ignore that, but 'docker' commands won't see the Lab (unset DOCKER_HOST or log in again, and use 'docker context use default')"
fi

env_file=$LAB_ROOT/.env
if [[ ! -f $env_file ]]; then
  warn ".env is missing: copy .env.example and fill it in (only the GPU Node recipes need it)"
else
  missing=$(comm -23 <(env_keys "$LAB_ROOT/.env.example") <(env_keys "$env_file"))
  if [[ -n $missing ]]; then
    warn ".env is missing keys from .env.example: $(echo "$missing" | paste -sd' ')"
  else
    ok ".env has every key in .env.example"
  fi
fi

exit $((fails > 0))

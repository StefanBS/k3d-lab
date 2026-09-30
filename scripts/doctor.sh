#!/usr/bin/env bash
# Checks that the Host has what the Lab needs. Installs nothing; prints hints instead.

# Saved before lib.sh pins DOCKER_HOST to Docker CE: the Podman check below needs the
# caller's own value.
caller_docker_host=${DOCKER_HOST:-}
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# True if version $1 is $2 or newer.
version_at_least() {
  [[ $(printf '%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]
}

# The variable names a .env-style file assigns, sorted.
env_keys() {
  sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$1" | sort
}

declare -A hints=(
  [docker]="install Docker CE: https://docs.docker.com/engine/install/fedora/"
  [k3d]="https://k3d.io/stable/#installation"
  [kubectl]="https://kubernetes.io/docs/tasks/tools/"
  [yq]="sudo dnf install yq (mikefarah's yq v4)"
  [helm]="https://helm.sh/docs/intro/install/"
  [just]="https://just.systems/man/en/packages.html"
  [shellcheck]="https://github.com/koalaman/shellcheck#installing (only 'just lint' needs it)"
  [kubeconform]="https://github.com/yannh/kubeconform#installation (only 'just lint' needs it)"
)
for tool in docker k3d kubectl helm just yq shellcheck kubeconform; do
  if command -v "$tool" >/dev/null; then
    ok "$tool is installed"
  else
    fail "$tool is missing: ${hints[$tool]}"
  fi
done

if command -v k3d >/dev/null; then
  k3d_version=$(k3d version | sed -n 's/^k3d version v//p')
  if version_at_least "$k3d_version" 5.9.0; then
    ok "k3d $k3d_version is 5.9 or newer"
  else
    fail "k3d $k3d_version is too old; the Lab needs 5.9 or newer: ${hints[k3d]}"
  fi
fi

# The Python tool also called yq takes different arguments, and prints JSON.
if command -v yq >/dev/null; then
  if yq --version 2>&1 | grep -q mikefarah; then
    ok "yq is mikefarah's yq"
  else
    fail "yq isn't mikefarah's yq, which the Lab's scripts use: ${hints[yq]}"
  fi
fi

if engine=$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null) && [[ $engine == Docker* ]]; then
  ok "Docker CE is running ($DOCKER_HOST)"
else
  fail "Docker CE isn't reachable at $DOCKER_HOST (ADR 0001)"
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

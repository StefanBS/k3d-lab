#!/usr/bin/env bash
# Checks that the Host has what the Lab needs. Installs nothing; prints hints instead.
caller_docker_host=${DOCKER_HOST:-}
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

fails=0
ok() { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

declare -A hints=(
  [docker]="install Docker CE: https://docs.docker.com/engine/install/fedora/"
  [k3d]="https://k3d.io/stable/#installation"
  [kubectl]="https://kubernetes.io/docs/tasks/tools/"
  [helm]="https://helm.sh/docs/intro/install/"
  [just]="https://just.systems/man/en/packages.html"
  [shellcheck]="https://github.com/koalaman/shellcheck#installing (only 'just lint' needs it)"
)
for tool in docker k3d kubectl helm just shellcheck; do
  if command -v "$tool" >/dev/null; then
    ok "$tool is installed"
  else
    fail "$tool is missing: ${hints[$tool]}"
  fi
done

if command -v k3d >/dev/null; then
  k3d_version=$(k3d version | sed -n 's/^k3d version v//p')
  if [[ $(printf '%s\n' 5.9.0 "$k3d_version" | sort -V | head -n1) == 5.9.0 ]]; then
    ok "k3d $k3d_version is 5.9 or newer"
  else
    fail "k3d $k3d_version is too old; the Lab needs 5.9 or newer: ${hints[k3d]}"
  fi
fi

if engine=$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null) && [[ $engine == Docker* ]]; then
  ok "Docker CE is running ($DOCKER_HOST)"
else
  fail "Docker CE isn't reachable at $DOCKER_HOST (ADR 0001)"
fi

if [[ $caller_docker_host == *podman* ]]; then
  warn "your shell's DOCKER_HOST points at Podman; the Lab's recipes ignore it, but plain 'docker' commands won't reach the Lab (log in again, or use 'docker --context default')"
fi

env_file=$LAB_ROOT/.env
if [[ ! -f $env_file ]]; then
  warn ".env is missing: copy .env.example and fill it in (only the GPU Node recipes need it)"
else
  missing=$(comm -23 \
    <(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$LAB_ROOT/.env.example" | sort) \
    <(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$env_file" | sort))
  if [[ -n $missing ]]; then
    warn ".env is missing keys from .env.example: $(echo "$missing" | paste -sd' ')"
  else
    ok ".env has every key in .env.example"
  fi
fi

exit $((fails > 0))

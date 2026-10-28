# Shared by the Lab's scripts: sourced, never run directly. Only the bootstrap: the
# shell options, the tools, the Docker engine, .env, and the modules in lib/, where every
# function lives (lint checks this file defines none).
# shellcheck shell=bash

set -euo pipefail

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The tools come from mise.toml, at the versions CI uses, whatever the caller's PATH
# holds. Without mise, the scripts use PATH as it is, and doctor says what's missing.
if command -v mise >/dev/null; then
  eval "$(cd "$LAB_ROOT" && mise env --shell bash)"
fi

# ADR 0001: the k3d Nodes run on Docker CE. Never trust the caller's DOCKER_HOST,
# which may point at another engine, such as Podman or rootless Docker.
export DOCKER_HOST=unix:///var/run/docker.sock

# Machine-specific values, never committed (.env.example lists them). Loaded here, so
# the scripts see them also when run without just.
LAB_ENV_FILE=$LAB_ROOT/.env
if [[ -f $LAB_ENV_FILE ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$LAB_ENV_FILE"
  set +a
fi

# The modules every script uses. output and lab come first, since the others call them.
# shellcheck source=lib/output.sh
source "$LAB_ROOT/scripts/lib/output.sh"
# shellcheck source=lib/lab.sh
source "$LAB_ROOT/scripts/lib/lab.sh"
# shellcheck source=lib/lab-repo.sh
source "$LAB_ROOT/scripts/lib/lab-repo.sh"
# shellcheck source=lib/wait.sh
source "$LAB_ROOT/scripts/lib/wait.sh"
# shellcheck source=lib/below.sh
source "$LAB_ROOT/scripts/lib/below.sh"
# shellcheck source=lib/gpu-node-ssh.sh
source "$LAB_ROOT/scripts/lib/gpu-node-ssh.sh"

# One module per Lab object: each reads, changes and waits for it through kc.
# shellcheck source=lib/applications.sh
source "$LAB_ROOT/scripts/lib/applications.sh"
# shellcheck source=lib/applicationsets.sh
source "$LAB_ROOT/scripts/lib/applicationsets.sh"
# shellcheck source=lib/nodes.sh
source "$LAB_ROOT/scripts/lib/nodes.sh"
# shellcheck source=lib/root-application.sh
source "$LAB_ROOT/scripts/lib/root-application.sh"
# shellcheck source=lib/pauses.sh
source "$LAB_ROOT/scripts/lib/pauses.sh"
# shellcheck source=lib/daemonsets.sh
source "$LAB_ROOT/scripts/lib/daemonsets.sh"
# shellcheck source=lib/namespaces.sh
source "$LAB_ROOT/scripts/lib/namespaces.sh"
# What each run waits for once it has changed the Lab, through the modules above.
# shellcheck source=lib/settling.sh
source "$LAB_ROOT/scripts/lib/settling.sh"

# shellcheck source=lib/components.sh
source "$LAB_ROOT/scripts/lib/components.sh"
# shellcheck source=lib/platform-facts.sh
source "$LAB_ROOT/scripts/lib/platform-facts.sh"

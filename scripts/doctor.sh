#!/usr/bin/env bash
# Checks that the Host has what the Lab needs. Installs nothing; prints hints instead.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

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
  ok "Docker CE answers at $DOCKER_HOST"
else
  fail "Docker CE isn't reachable at $DOCKER_HOST (ADR 0001): https://docs.docker.com/engine/install/fedora/"
fi

# k3s evicts pods and taints the node when its image filesystem drops below 15% free,
# and the k3d Nodes keep theirs in Docker's data directory (ADR 0001).
# Where host-setup put it, when Docker CE can't say.
data_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) || data_root=$DOCKER_DATA_ROOT
if [[ ! -d $data_root ]]; then
  warn "Docker's data directory $data_root doesn't exist yet: run 'just host-setup'"
else
  read -r avail size < <(df --output=avail,size --block-size=1G "$data_root" | tail -1)
  free_pct=$((100 * avail / size))
  if ((free_pct < 20)); then
    warn "Docker's data directory $data_root has only ${avail} GiB free (${free_pct}%); k3s evicts pods below 15%"
  else
    ok "Docker's data directory $data_root has ${avail} GiB free (${free_pct}%)"
  fi
fi

# What host-setup does, including the steps that need root.
if [[ -f $LAB_CA_CERT ]]; then
  ok "the Lab CA exists ($LAB_CA_DIR)"
else
  warn "the Lab CA is missing ($LAB_CA_CERT): run 'just host-setup'"
fi
# shellcheck disable=SC2329  # called by run_root_steps
not_set_up() { warn "not yet: $2 (run 'just host-setup')"; }
run_root_steps not_set_up

if [[ ! -f $LAB_ENV_FILE ]]; then
  warn ".env is missing: copy .env.example and fill it in (only the GPU Node recipes need it)"
else
  missing=$(comm -23 <(env_keys "$LAB_ROOT/.env.example") <(env_keys "$LAB_ENV_FILE"))
  if [[ -n $missing ]]; then
    warn ".env is missing keys from .env.example: $(paste -sd' ' <<<"$missing")"
  else
    ok ".env has every key in .env.example"
  fi
  # The GPU Node routes the Lab's subnet through this address (ADR 0002).
  lan_ip=$(host_lan_ip)
  if [[ $(sed -n 's/^HOST_LAN_IP=//p' "$LAB_ENV_FILE") == "$lan_ip" ]]; then
    ok "HOST_LAN_IP in .env is the Host's address ($lan_ip)"
  else
    warn "HOST_LAN_IP in .env isn't the Host's address ($lan_ip): run 'just host-wizard' before joining the GPU Node"
  fi
fi

exit $((fails > 0))

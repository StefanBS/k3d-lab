#!/usr/bin/env bash
# Checks that the Host has what the Lab needs. Installs nothing; prints hints instead.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"
# shellcheck source=secret-store.sh
source "$(dirname "$0")/secret-store.sh"
# shellcheck source=host-memory.sh
source "$(dirname "$0")/host-memory.sh"

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

# Below 15% free, the kubelet deletes unused images, which slows the next `just up`;
# below 5%, it evicts pods and taints the node disk-pressure. The k3d Nodes keep their
# images in Docker's data directory (ADR 0001).
# Where `just host setup` put it, when Docker CE can't say.
data_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) || data_root=$DOCKER_DATA_ROOT
if [[ ! -d $data_root ]]; then
  warn "Docker's data directory $data_root doesn't exist yet: run 'just host setup'"
else
  read -r avail size < <(df --output=avail,size --block-size=1G "$data_root" | tail -1)
  free_pct=$((100 * avail / size))
  if ((free_pct < 20)); then
    warn "Docker's data directory $data_root has only ${avail} GiB free (${free_pct}%); the kubelet deletes unused images below 15% and evicts pods below 5%"
  else
    ok "Docker's data directory $data_root has ${avail} GiB free (${free_pct}%)"
  fi
fi

if short=$(host_memory_short </proc/meminfo); then
  warn "$short; close what you can before 'just up' or 'just verify'"
fi

# The Lab's Gateway is published on these (k3d/cluster.yaml); a running Lab holds them itself.
if ! lab_exists; then
  taken=$(lab_host_ports_taken)
  if [[ -n $taken ]]; then
    fail "the Lab's Gateway needs Host ports ${LAB_HOST_PORTS[*]}, but something listens on $(paste -sd' ' <<<"$taken")"
  else
    ok "Host ports ${LAB_HOST_PORTS[*]} are free for the Lab's Gateway"
  fi
fi

# Every step `just host setup` does, including the ones that need root. ADR 0003: up needs
# the Secret Store, and ESO reads from it in every Lab.
report_host_steps

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
  if why=$(host_lan_ip_current); then
    ok "HOST_LAN_IP in .env is the Host's address ($HOST_LAN_IP)"
  else
    warn "$why: run 'just host wizard' before joining the GPU Node"
  fi
fi

exit $((fails > 0))

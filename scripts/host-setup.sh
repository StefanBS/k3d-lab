#!/usr/bin/env bash
# Prepares the Host once (ADRs 0001 and 0003), as the Lab's owner. Safe to re-run:
# each step checks first, and a run with nothing to do says so.
# The steps that need root are in host-setup-root.sh, which you run yourself;
# this checks them and tells you when to.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

pending=0
# check_root_step <description> <check> [args...]: host-setup-root.sh does the step.
check_root_step() {
  local description=$1
  shift
  if "$@"; then
    ok "$description"
  else
    warn "not yet: $description"
    pending=$((pending + 1))
  fi
}

# Marks the lines this script disabled, so you can find and restore them.
disabled_marker='# disabled by k3d-lab ADR 0001 (use docker contexts): '
podman_socket=unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock

log "Lab CA"
if [[ -f $LAB_CA_CERT && -f $LAB_CA_KEY ]]; then
  ok "the Lab CA exists ($LAB_CA_DIR)"
elif [[ -e $LAB_CA_CERT || -e $LAB_CA_KEY ]]; then
  die "only half of the Lab CA is in $LAB_CA_DIR; restore the other half, or delete both to start over (everything it signed must then be trusted again)"
else
  changed "Generating the Lab CA in $LAB_CA_DIR"
  (
    umask 077
    mkdir -p "$LAB_CA_DIR"
    # Name constraints limit what the CA can vouch for to the Lab's names and addresses,
    # since the Host trusts it everywhere and its key sits unencrypted in your home.
    openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
      -keyout "$LAB_CA_KEY" -out "$LAB_CA_CERT" -days 3650 \
      -subj "/CN=k3d-lab Lab CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "nameConstraints=critical,permitted;DNS:localtest.me,permitted;DNS:k3d.internal,permitted;IP:${LAB_SUBNET%/*}/$LAB_SUBNET_NETMASK,permitted;IP:127.0.0.0/255.0.0.0" \
      2>/dev/null
  )
  chmod 0644 "$LAB_CA_CERT"
fi

log "Root steps (sudo scripts/host-setup-root.sh)"
check_root_step "podman-docker isn't installed" podman_docker_removed
check_root_step "Docker CE is installed" docker_ce_installed
check_root_step "Docker CE keeps its data in $DOCKER_DATA_ROOT" docker_data_root_set
check_root_step "SELinux labels $DOCKER_DATA_ROOT like /var/lib/docker" docker_data_root_labelled
check_root_step "Docker CE is running and starts at boot" docker_ce_running
check_root_step "$USER is in the docker group" in_docker_group "$USER"
check_root_step "the Host trusts the Lab CA" lab_ca_trusted

log "Docker CLI contexts"
if ! docker_ce_installed; then
  # Until then, docker may be podman-docker's shim, which answers for Podman.
  warn "not yet: the Docker contexts need Docker CE's CLI"
  pending=$((pending + 1))
elif docker context inspect podman >/dev/null 2>&1; then
  ok "'docker --context podman' reaches Podman; the default context is Docker CE"
else
  changed "Creating the 'podman' Docker context ($podman_socket)"
  docker context create podman --docker "host=$podman_socket" >/dev/null
fi

# Shell startup files and systemd's user environment that point docker at Podman.
# Disabled rather than deleted, so they can be restored.
for rc in ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc ~/.bashrc.d/*; do
  [[ -f $rc ]] || continue
  pattern='^[[:space:]]*(export[[:space:]]+)?(DOCKER_HOST|DOCKER_SOCK)=.*podman'
  if grep -Eq "$pattern" "$rc"; then
    changed "Disabling the DOCKER_HOST export in $rc (open shells keep it until you log in again)"
    sed -Ei "s|$pattern|$disabled_marker&|" "$rc"
  fi
done
for conf in ~/.config/environment.d/*.conf; do
  [[ -f $conf ]] || continue # no files leaves the glob unexpanded
  if grep -Eq '^DOCKER_HOST=.*podman' "$conf"; then
    changed "Disabling $conf, which sets DOCKER_HOST to Podman"
    mv "$conf" "$conf.bak-k3d-lab-disabled"
  fi
done
if systemctl --user show-environment 2>/dev/null | grep -Eq '^DOCKER_HOST=.*podman'; then
  changed "Unsetting DOCKER_HOST in systemd's user environment"
  systemctl --user unset-environment DOCKER_HOST
fi
ok "nothing points docker at Podman by default"
# The group database has it, but this login session was started without it.
if in_docker_group "$USER" && ! id -nG | tr ' ' '\n' | grep -qx docker; then
  warn "this session isn't in the docker group yet: log in again to use docker and k3d without sudo"
fi

# Only the GPU Node needs this (ADR 0002), and only you can make the reservation.
log "Host LAN address"
lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
env_ip=""
[[ ! -f $LAB_ROOT/.env ]] || env_ip=$(sed -n 's/^HOST_LAN_IP=//p' "$LAB_ROOT/.env" | tail -1)
if [[ -n $lan_ip && $env_ip == "$lan_ip" ]]; then
  ok "HOST_LAN_IP in .env is the Host's address ($lan_ip)"
else
  warn "HOST_LAN_IP in .env isn't the Host's address ($lan_ip): run 'just host-wizard' before joining the GPU Node"
fi

if ((pending > 0)); then
  die "$pending step(s) need root. Run this yourself, then 'just host-setup' again:
  sudo scripts/host-setup-root.sh"
elif ((changes == 0)); then
  log "Nothing to change: the Host is already set up"
else
  log "Made $changes change(s); the Host is set up"
fi

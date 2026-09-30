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
      -addext "nameConstraints=critical,permitted;DNS:lab.localhost,permitted;DNS:k3d.internal,permitted;IP:${LAB_SUBNET%/*}/$LAB_SUBNET_NETMASK,permitted;IP:127.0.0.0/255.0.0.0" \
      2>/dev/null
  )
  chmod 0644 "$LAB_CA_CERT"
fi

log "Root steps (sudo scripts/host-setup-root.sh)"
for ((i = 0; i < ${#ROOT_STEPS[@]}; i += 2)); do
  if "${ROOT_STEPS[i]}"; then
    ok "${ROOT_STEPS[i + 1]}"
  else
    warn "not yet: ${ROOT_STEPS[i + 1]}"
    pending=$((pending + 1))
  fi
done

# The group database has it, but this login session was started without it.
if owner_in_docker_group && ! in_docker_group; then
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

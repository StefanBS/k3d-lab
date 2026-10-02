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
if lab_ca_exists; then
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
not_yet() {
  warn "not yet: $2"
  pending=$((pending + 1))
}
run_root_steps not_yet

# The group database has it, but this login session was started without it.
if owner_in_docker_group && ! in_docker_group; then
  warn "this session isn't in the docker group yet: log in again to use docker and k3d without sudo"
fi

# The Secret Store waits for the root steps, so it never listens before the firewall
# keeps the LAN out.
((pending == 0)) || die "$pending step(s) need root. Run this yourself, then 'just host-setup' again:
  sudo scripts/host-setup-root.sh"

log "Secret Store"
# Writes stdin to a file if it would change it. Fails if it's unchanged, so a caller
# knows whether to restart what reads it.
write_if_changed() {
  local new
  new=$(cat)
  [[ -f $1 && $(<"$1") == "$new" ]] && return 1
  printf '%s\n' "$new" >"$1"
}

# A user unit only starts at boot, before you log in, with lingering.
if [[ $(loginctl show-user "$LAB_OWNER" -p Linger --value 2>/dev/null) == yes ]]; then
  ok "$LAB_OWNER's user services start at boot (lingering)"
else
  changed "Enabling lingering, so $LAB_OWNER's user services start at boot"
  loginctl enable-linger "$LAB_OWNER"
fi

# The unseal key is generated once: OpenBao's data can't be read without the key it
# was sealed with.
if [[ -f $SECRET_STORE_UNSEAL_KEY ]]; then
  ok "the Secret Store's unseal key exists ($SECRET_STORE_UNSEAL_KEY)"
elif [[ -e $SECRET_STORE_DATA ]]; then
  die "$SECRET_STORE_DATA exists, but its unseal key doesn't; restore $SECRET_STORE_UNSEAL_KEY from a vault-backup, or delete $SECRET_STORE_DIR to start over (its secrets are lost)"
else
  changed "Generating the Secret Store's unseal key"
  (
    umask 077
    mkdir -p "$SECRET_STORE_DIR"
    openssl rand -out "$SECRET_STORE_UNSEAL_KEY" 32
  )
fi
restart=false

# Renewed a month before it expires, or when the Lab CA is new.
if [[ -f $SECRET_STORE_TLS_CERT ]] &&
  openssl x509 -in "$SECRET_STORE_TLS_CERT" -noout -checkend $((30 * 86400)) >/dev/null &&
  openssl verify -CAfile "$LAB_CA_CERT" "$SECRET_STORE_TLS_CERT" >/dev/null 2>&1; then
  ok "the Secret Store's TLS certificate is from the Lab CA, and valid for 30 more days"
else
  changed "Signing the Secret Store's TLS certificate with the Lab CA"
  (
    umask 077
    # For the Lab, by name, and for the bao CLI inside the container.
    openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
      -CA "$LAB_CA_CERT" -CAkey "$LAB_CA_KEY" \
      -keyout "$SECRET_STORE_TLS_KEY" -out "$SECRET_STORE_TLS_CERT" -days 3650 \
      -subj "/CN=$SECRET_STORE_HOST" \
      -addext "subjectAltName=DNS:$SECRET_STORE_HOST,IP:127.0.0.1" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "extendedKeyUsage=serverAuth" \
      2>/dev/null
  )
  install -m 0644 "$LAB_CA_CERT" "$SECRET_STORE_CA_CERT"
  restart=true
fi

# Paths here are inside the container, where SECRET_STORE_DIR is /openbao/state.
# OpenBao 2.7 has no file storage, so it's single-node Raft: still one data directory.
if write_if_changed "$SECRET_STORE_CONFIG" <<EOF; then
# Written by 'just host-setup' (scripts/host-setup.sh); changes here are overwritten.
ui = false
api_addr = "https://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
storage "raft" {
  path = "/openbao/state/data"
  node_id = "secret-store"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/openbao/state/tls.crt"
  tls_key_file = "/openbao/state/tls.key"
}
# Unseals itself at every start with this key (ADR 0003).
seal "static" {
  current_key_id = "1"
  current_key = "file:///openbao/state/unseal.key"
}
EOF
  changed "Writing the Secret Store's configuration"
  restart=true
else
  ok "the Secret Store's configuration is up to date"
fi
mkdir -p "$SECRET_STORE_DATA" "$(dirname "$SECRET_STORE_QUADLET")"

# keep-id maps the owner to the image's openbao user (100:1000), so the owner owns
# every file OpenBao writes, and vault-backup can read them.
if write_if_changed "$SECRET_STORE_QUADLET" <<EOF; then
# Written by 'just host-setup' (scripts/host-setup.sh); changes here are overwritten.
[Unit]
Description=k3d-lab Secret Store (OpenBao)

[Container]
ContainerName=$SECRET_STORE_UNIT
Image=$SECRET_STORE_IMAGE
Entrypoint=bao
Exec=server -config=/openbao/state/openbao.hcl
UserNS=keep-id:uid=100,gid=1000
Volume=$SECRET_STORE_DIR:/openbao/state:Z
# Every address, so the Lab reaches it on its gateway, which only exists while there's
# a Lab. The firewall admits only the Lab's subnet ($SECRET_STORE_FIREWALL_POLICY).
PublishPort=$SECRET_STORE_PORT:8200
# For the bao CLI that scripts/bao.sh runs in the container.
Environment=BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/state/ca.crt

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF
  changed "Writing the Secret Store's Quadlet ($SECRET_STORE_QUADLET)"
  quietly podman pull "$SECRET_STORE_IMAGE"
  systemctl --user daemon-reload
  restart=true
else
  ok "the Secret Store's Quadlet is up to date"
fi

if [[ $restart == true ]] && secret_store_running; then
  changed "Restarting the Secret Store"
  systemctl --user restart "$SECRET_STORE_UNIT"
elif ! secret_store_running; then
  changed "Starting the Secret Store"
  systemctl --user start "$SECRET_STORE_UNIT"
fi
# Answers once it's listening, sealed or not.
retry 30 secret_store_answers || die "the Secret Store doesn't answer; see: journalctl --user -u $SECRET_STORE_UNIT"
ok "the Secret Store is running"

# Once ever. The root token never leaves the Host; scripts/bao.sh uses it.
if [[ $(bao_status | yq -p json -o yaml '.initialized') == true ]]; then
  ok "the Secret Store is initialised"
else
  changed "Initialising the Secret Store ($SECRET_STORE_INIT holds its root token)"
  (
    umask 077
    podman exec "$SECRET_STORE_UNIT" bao operator init -recovery-shares=1 -recovery-threshold=1 \
      -format=json >"$SECRET_STORE_INIT"
  )
fi
retry 30 secret_store_unsealed || die "the Secret Store is sealed; see: journalctl --user -u $SECRET_STORE_UNIT"
ok "the Secret Store is unsealed"

# Where Workloads' secrets live: lab/workloads/<workload>/<key>.
if bao_enabled secrets lab; then
  ok "the Secret Store has the KV v2 mount lab/"
else
  changed "Creating the KV v2 mount lab/"
  quietly "$LAB_ROOT/scripts/bao.sh" secrets enable -path=lab -version=2 kv
fi

if ((changes == 0)); then
  log "Nothing to change: the Host is already set up"
else
  log "Made $changes change(s); the Host is set up"
fi

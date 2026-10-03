#!/usr/bin/env bash
# The Secret Store (ADR 0003): everything about the OpenBao on the Host that holds the
# secrets Workloads need. Two ways in:
#   - Sourced after lib.sh and host.sh, by host-setup.sh, doctor.sh and up.sh: it adds
#     its steps to the Host's (HOST_STEPS), and gives up.sh secret_store_trust_lab.
#   - Run, as secret-store.sh <subcommand> (just secret-store <recipe>):
#       bao <arguments>  Runs the bao CLI as the Secret Store's root, such as:
#                        kv put -mount=lab workloads/<workload>/<key> <field>=<value>
#                        Reads stdin, for arguments like <field>=-.
#       backup <path>    Archives SECRET_STORE_DIR. A directory gets a new archive named
#                        by the date and time; any other path is the archive itself,
#                        which must not exist yet.
#       trust-lab        Makes the Lab and the Secret Store trust each other.
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file
# shellcheck disable=SC2329  # the fix_* and blocked_* functions are called by name

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  # shellcheck source=lib.sh
  source "$(dirname "$0")/lib.sh"
  # shellcheck source=host.sh
  source "$(dirname "$0")/host.sh"
fi

# OpenBao, as a rootless Podman Quadlet of the owner's. All of its state lives in
# SECRET_STORE_DIR, which backup archives: the Raft data, the unseal key, the root token,
# and its TLS certificate from the Lab CA.
SECRET_STORE_DIR=$LAB_HOST_DIR/secret-store
SECRET_STORE_UNSEAL_KEY=$SECRET_STORE_DIR/unseal.key
# What `bao operator init` printed: the root token and the recovery key.
SECRET_STORE_INIT=$SECRET_STORE_DIR/init.json
SECRET_STORE_DATA=$SECRET_STORE_DIR/data
SECRET_STORE_CONFIG=$SECRET_STORE_DIR/openbao.hcl
SECRET_STORE_TLS_CERT=$SECRET_STORE_DIR/tls.crt
SECRET_STORE_TLS_KEY=$SECRET_STORE_DIR/tls.key
# The Lab CA's certificate, for the bao CLI inside the container.
SECRET_STORE_CA_CERT=$SECRET_STORE_DIR/ca.crt
# From ghcr.io: pulling from quay.io failed on the Host.
# renovate: datasource=docker depName=ghcr.io/openbao/openbao
SECRET_STORE_IMAGE=ghcr.io/openbao/openbao:2.7.1
SECRET_STORE_UNIT=k3d-lab-secret-store
SECRET_STORE_QUADLET=$LAB_OWNER_HOME/.config/containers/systemd/$SECRET_STORE_UNIT.container
SECRET_STORE_PORT=8200
# How ESO reaches the Host: its gateway on the Lab network (platform/external-secrets/).
SECRET_STORE_HOST=host.k3d.internal
# The firewalld policy that admits only the Lab's subnet to SECRET_STORE_PORT. It runs
# before every zone: the Lab's bridge is in Docker's zone, which accepts everything, and
# Fedora Workstation's default zone accepts every port above 1024 from the LAN.
SECRET_STORE_FIREWALL_POLICY=k3d-lab-secret-store
SECRET_STORE_FIREWALL_RULES=(
  "rule priority=\"-2\" family=\"ipv4\" source address=\"$LAB_SUBNET\" port port=\"$SECRET_STORE_PORT\" protocol=\"tcp\" accept"
  "rule priority=\"-1\" port port=\"$SECRET_STORE_PORT\" protocol=\"tcp\" reject"
)

# After the Host's own steps, in order: the firewall first, so the Secret Store never
# listens before the LAN is kept out. Lingering starts it at boot, before you log in.
HOST_STEPS+=(
  secret_store_firewalled root "only the Lab's subnet can reach the Secret Store's port $SECRET_STORE_PORT"
  owner_lingers owner "$LAB_OWNER's user services start at boot (lingering)"
  secret_store_unseal_key_exists owner "the Secret Store's unseal key exists ($SECRET_STORE_UNSEAL_KEY)"
  secret_store_tls_valid owner "the Secret Store's TLS certificate is from the Lab CA, and valid for 30 more days"
  secret_store_config_current owner "the Secret Store's configuration is up to date"
  secret_store_quadlet_current owner "the Secret Store's Quadlet is up to date"
  secret_store_runs_current_config owner "the Secret Store is running, started since its configuration last changed"
  secret_store_initialised owner "the Secret Store is initialised"
  secret_store_unsealed owner "the Secret Store is unsealed"
  secret_store_has_kv_mount owner "the Secret Store has the KV v2 mount lab/"
)

# In the running firewall. Only root can query the permanent configuration without
# polkit asking for a password, but the fix writes it there and reloads.
secret_store_firewalled() {
  local rule
  for rule in "${SECRET_STORE_FIREWALL_RULES[@]}"; do
    firewall-cmd -q --policy "$SECRET_STORE_FIREWALL_POLICY" --query-rich-rule "$rule" 2>/dev/null || return 1
  done
}
fix_secret_store_firewalled() {
  changed "Letting only $LAB_SUBNET reach port $SECRET_STORE_PORT (firewalld policy $SECRET_STORE_FIREWALL_POLICY)"
  local policy=(--permanent --policy "$SECRET_STORE_FIREWALL_POLICY") rule
  firewall-cmd -q --permanent --info-policy "$SECRET_STORE_FIREWALL_POLICY" >/dev/null 2>&1 ||
    firewall-cmd -q --permanent --new-policy "$SECRET_STORE_FIREWALL_POLICY"
  # Traffic from any zone to the Host itself, before any zone's own rules.
  firewall-cmd -q "${policy[@]}" --set-priority -100
  firewall-cmd -q "${policy[@]}" --add-ingress-zone ANY
  firewall-cmd -q "${policy[@]}" --add-egress-zone HOST
  for rule in "${SECRET_STORE_FIREWALL_RULES[@]}"; do
    firewall-cmd -q "${policy[@]}" --add-rich-rule "$rule"
  done
  firewall-cmd -q --reload
}

# A user unit only starts at boot, before you log in, with lingering.
owner_lingers() { [[ $(loginctl show-user "$LAB_OWNER" -p Linger --value 2>/dev/null) == yes ]]; }
fix_owner_lingers() {
  changed "Enabling lingering, so $LAB_OWNER's user services start at boot"
  loginctl enable-linger "$LAB_OWNER"
}

# The Secret Store's steps from here on need its user systemd, so only the owner fixes
# them. The unseal key is generated once: OpenBao's data can't be read without the key
# it was sealed with.
secret_store_unseal_key_exists() { [[ -f $SECRET_STORE_UNSEAL_KEY ]]; }
blocked_secret_store_unseal_key_exists() {
  ! secret_store_unseal_key_exists && [[ -e $SECRET_STORE_DATA ]] &&
    echo "$SECRET_STORE_DATA exists, but its unseal key doesn't; restore $SECRET_STORE_UNSEAL_KEY from a 'just secret-store backup' archive, or delete $SECRET_STORE_DIR to start over (its secrets are lost)"
}
fix_secret_store_unseal_key_exists() {
  changed "Generating the Secret Store's unseal key"
  (
    umask 077
    mkdir -p "$SECRET_STORE_DIR"
    openssl rand -out "$SECRET_STORE_UNSEAL_KEY" 32
  )
}

# Renewed a month before it expires, or when the Lab CA is new.
secret_store_tls_valid() {
  [[ -f $SECRET_STORE_TLS_CERT ]] &&
    openssl x509 -in "$SECRET_STORE_TLS_CERT" -noout -checkend $((30 * 86400)) >/dev/null &&
    openssl verify -CAfile "$LAB_CA_CERT" "$SECRET_STORE_TLS_CERT" >/dev/null 2>&1
}
fix_secret_store_tls_valid() {
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
}

# Paths here are inside the container, where SECRET_STORE_DIR is /openbao/state.
# OpenBao 2.7 has no file storage, so it's single-node Raft: still one data directory.
secret_store_config() {
  cat <<EOF
# Written by 'just host setup' (scripts/host-setup.sh); changes here are overwritten.
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
}
secret_store_config_current() { [[ -f $SECRET_STORE_CONFIG && $(<"$SECRET_STORE_CONFIG") == "$(secret_store_config)" ]]; }
fix_secret_store_config_current() {
  changed "Writing the Secret Store's configuration"
  secret_store_config >"$SECRET_STORE_CONFIG"
}

# keep-id maps the owner to the image's openbao user (100:1000), so the owner owns
# every file OpenBao writes, and `just secret-store backup` can read them.
secret_store_quadlet() {
  cat <<EOF
# Written by 'just host setup' (scripts/host-setup.sh); changes here are overwritten.
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
# For the bao CLI that scripts/secret-store.sh runs in the container.
Environment=BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/openbao/state/ca.crt

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF
}
secret_store_quadlet_current() { [[ -f $SECRET_STORE_QUADLET && $(<"$SECRET_STORE_QUADLET") == "$(secret_store_quadlet)" ]]; }
fix_secret_store_quadlet_current() {
  changed "Writing the Secret Store's Quadlet ($SECRET_STORE_QUADLET)"
  mkdir -p "$(dirname "$SECRET_STORE_QUADLET")"
  secret_store_quadlet >"$SECRET_STORE_QUADLET"
  quietly podman pull "$SECRET_STORE_IMAGE"
}

secret_store_running() { systemctl --user -q is-active "$SECRET_STORE_UNIT"; }
# OpenBao reads its configuration, Quadlet and certificate only when it starts.
secret_store_runs_current_config() {
  local started file
  secret_store_running || return 1
  started=$(systemctl --user show -p ActiveEnterTimestamp --value --timestamp=unix "$SECRET_STORE_UNIT")
  started=${started#@}
  for file in "$SECRET_STORE_CONFIG" "$SECRET_STORE_QUADLET" "$SECRET_STORE_TLS_CERT"; do
    [[ -f $file ]] && (($(stat -c %Y "$file") <= started)) || return 1
  done
}
fix_secret_store_runs_current_config() {
  if secret_store_running; then
    changed "Restarting the Secret Store on its current configuration"
  else
    changed "Starting the Secret Store"
  fi
  mkdir -p "$SECRET_STORE_DATA"
  # Turns the Quadlet into the unit that systemd runs.
  systemctl --user daemon-reload
  systemctl --user restart "$SECRET_STORE_UNIT"
  # Answers once it's listening, sealed or not.
  retry 30 secret_store_answers || die "the Secret Store doesn't answer; see: journalctl --user -u $SECRET_STORE_UNIT"
}

# bao_status: `bao status` in the container, as JSON. Exits 0 if unsealed, 2 if sealed
# or not initialised yet, and 1 if OpenBao doesn't answer.
bao_status() {
  podman exec "$SECRET_STORE_UNIT" bao status -format=json 2>/dev/null
}
secret_store_answers() {
  local status=0
  bao_status >/dev/null || status=$?
  ((status != 1))
}

# Once ever. The root token never leaves the Host; secret_store_bao uses it.
secret_store_initialised() { [[ $(bao_status | yq -p json -o yaml '.initialized') == true ]]; }
fix_secret_store_initialised() {
  changed "Initialising the Secret Store ($SECRET_STORE_INIT holds its root token)"
  (
    umask 077
    podman exec "$SECRET_STORE_UNIT" bao operator init -recovery-shares=1 -recovery-threshold=1 \
      -format=json >"$SECRET_STORE_INIT"
  )
}

secret_store_unsealed() { bao_status >/dev/null; }
# It unseals itself with the static seal; this only waits for it.
fix_secret_store_unsealed() {
  retry 30 secret_store_unsealed || die "the Secret Store is sealed; see: journalctl --user -u $SECRET_STORE_UNIT"
}

# bao_enabled <secrets|auth> <path>: whether that secrets engine or auth method is
# enabled at <path>/.
bao_enabled() {
  [[ $(secret_store_bao "$1" list -format=json | yq -p json -o yaml "has(\"$2/\")") == true ]]
}

# Where Workloads' secrets live: lab/workloads/<workload>/<key>.
secret_store_has_kv_mount() { bao_enabled secrets lab 2>/dev/null; }
fix_secret_store_has_kv_mount() {
  changed "Creating the KV v2 mount lab/"
  quietly secret_store_bao secrets enable -path=lab -version=2 kv
}

# secret_store_bao <bao arguments>: the bao CLI as the Secret Store's root. It runs
# inside the Secret Store's container, so the Host needs no bao of its own.
secret_store_bao() {
  [[ -f $SECRET_STORE_INIT ]] || die "the Secret Store isn't set up yet; run 'just host setup'"
  secret_store_running || die "the Secret Store isn't running; see: systemctl --user status $SECRET_STORE_UNIT"
  # Passed by name, so the token never shows up in the Host's process list.
  BAO_TOKEN=$(yq -p json -o yaml '.root_token' "$SECRET_STORE_INIT") \
    podman exec -i -e BAO_TOKEN "$SECRET_STORE_UNIT" bao "$@"
}

# secret_store_trust_lab: makes the Lab and the Secret Store trust each other. ESO reads
# Workloads' secrets with Kubernetes auth (platform/external-secrets/values.yaml), and
# every Lab has a new API CA, so the auth is pointed at it here. OpenBao keeps no token
# of the Lab's: it checks each login's token with a TokenReview made with that same
# token. ESO, in turn, trusts the Secret Store's certificate through the Lab CA.
secret_store_trust_lab() {
  local eso_ns eso_audience
  lab_exists || die "no Lab named '$LAB_NAME'; run 'just up'"
  log "Pointing the Secret Store's Kubernetes auth at the Lab"
  bao_enabled auth kubernetes || quietly secret_store_bao auth enable kubernetes
  # Read-only, and only Workloads' secrets: lab/workloads/<workload>/<key>.
  quietly secret_store_bao policy write eso - <<'EOF'
path "lab/data/workloads/*" { capabilities = ["read"] }
path "lab/metadata/workloads/*" { capabilities = ["read", "list"] }
EOF
  eso_ns=$(component_namespace platform/external-secrets)
  eso_audience=$(platform_fact eso.audience)
  quietly secret_store_bao write auth/kubernetes/role/eso \
    bound_service_account_names=external-secrets bound_service_account_namespaces="$eso_ns" \
    audience="$eso_audience" token_policies=eso token_ttl=1h
  kc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
    base64 -d | quietly secret_store_bao write auth/kubernetes/config \
    kubernetes_host="https://$(lab_server_ip):6443" kubernetes_ca_cert=- disable_local_ca_jwt=true
  # The ClusterSecretStore trusts the Secret Store's certificate through this.
  kc create namespace "$eso_ns" --dry-run=client -o yaml | kc apply --server-side -f - >/dev/null
  kc -n "$eso_ns" create configmap lab-ca --from-file=ca.crt="$LAB_CA_CERT" --dry-run=client -o yaml |
    kc apply --server-side -f - >/dev/null
}

# secret_store_backup <path>: OpenBao stops while it's archived, so the data can't change
# underneath: a few seconds in which the Lab can't read secrets, though the Secrets ESO
# already made stay. The archive can read every secret, so keep it safe.
secret_store_backup() {
  local archive=$1
  [[ ! -d $archive ]] || archive=$archive/k3d-lab-secret-store-$(date +%Y%m%d-%H%M%S).tar.gz
  [[ ! -e $archive ]] || die "$archive already exists"
  [[ -d $(dirname "$archive") ]] || die "$(dirname "$archive") isn't a directory"
  [[ -f $SECRET_STORE_INIT ]] || die "the Secret Store isn't set up yet; run 'just host setup'"
  # Started again however the archiving ends.
  if secret_store_running; then
    log "Stopping the Secret Store"
    systemctl --user stop "$SECRET_STORE_UNIT"
    trap secret_store_restart EXIT
  fi
  log "Archiving $SECRET_STORE_DIR to $archive"
  (
    umask 077
    tar -czf "$archive" -C "$(dirname "$SECRET_STORE_DIR")" "$(basename "$SECRET_STORE_DIR")"
  )
}
secret_store_restart() {
  systemctl --user start "$SECRET_STORE_UNIT"
  retry 30 secret_store_unsealed || die "the Secret Store didn't come back unsealed; see: journalctl --user -u $SECRET_STORE_UNIT"
  log "The Secret Store is running again"
}

main() {
  local cmd=${1:-}
  shift || true
  case $cmd in
    bao) secret_store_bao "$@" ;;
    backup)
      (($# == 1)) || die "usage: just secret-store backup <directory or archive path>"
      secret_store_backup "$1"
      ;;
    trust-lab)
      (($# == 0)) || die "usage: secret-store.sh trust-lab"
      secret_store_trust_lab
      ;;
    *) die "usage: secret-store.sh bao <arguments> | backup <path> | trust-lab" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

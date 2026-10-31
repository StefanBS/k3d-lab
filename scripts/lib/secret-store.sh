# The Secret Store (ADR 0003): everything about the OpenBao on the Host that holds the
# secrets that outlive a Lab: the ones Workloads need, and single sign-on's (ADR 0013).
# Sourced after lib.sh and lib/host.sh, by host-setup.sh, doctor.sh, up.sh, creds.sh and
# secret-store.sh, which runs it for `just secret-store`: it adds its steps to the Host's
# (HOST_STEPS), and gives up.sh secret_store_trust_lab.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file
# shellcheck disable=SC2329  # the fix_* and blocked_* functions are called by name

# shellcheck source=sso.sh
source "$(dirname "${BASH_SOURCE[0]}")/sso.sh"

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
SECRET_STORE_IMAGE=ghcr.io/openbao/openbao:2.7.2
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
# listens before the LAN is kept out. It never starts at boot: `just start` starts it.
HOST_STEPS+=(
  secret_store_firewalled root "only the Lab's subnet can reach the Secret Store's port $SECRET_STORE_PORT"
  owner_lingers owner "$LAB_OWNER's user services keep running after you log out (lingering)"
  secret_store_unseal_key_exists owner "Secret Store's unseal key exists ($SECRET_STORE_UNSEAL_KEY)"
  secret_store_tls_valid owner "Secret Store's TLS certificate is from the Lab CA, and valid for 30 more days"
  secret_store_config_current owner "Secret Store's configuration is up to date"
  secret_store_quadlet_current owner "Secret Store's Quadlet is up to date"
  secret_store_runs_current_config owner "Secret Store is running, started since its configuration last changed"
  secret_store_initialised owner "Secret Store is initialised"
  secret_store_unsealed owner "Secret Store is unsealed"
  secret_store_has_kv_mount owner "Secret Store has the KV v2 mount lab/"
  sso_secrets_exist owner "Secret Store has the Lab login and each OIDC client's secret"
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

# Without lingering, a user unit stops when your last session ends, so the Secret Store
# would go with it while the Lab runs on.
owner_lingers() { [[ $(loginctl show-user "$LAB_OWNER" -p Linger --value 2>/dev/null) == yes ]]; }
fix_owner_lingers() {
  changed "Enabling lingering, so $LAB_OWNER's user services keep running after you log out"
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

# No [Install] section, so it never starts at boot: 'just start' starts it.
[Service]
Restart=always
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
  wait_until_none 30 "the Secret Store doesn't answer; see: journalctl --user -u $SECRET_STORE_UNIT" \
    secret_store_unanswered
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
# For wait_until_none, which waits until they print nothing.
secret_store_unanswered() { secret_store_answers || echo "the Secret Store: not answering"; }
secret_store_sealed() { secret_store_unsealed || echo "the Secret Store: sealed, or not answering"; }

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
  wait_until_none 30 "the Secret Store is sealed; see: journalctl --user -u $SECRET_STORE_UNIT" secret_store_sealed
}

# bao_enabled <secrets|auth> <path>: whether that secrets engine or auth method is
# enabled at <path>/.
bao_enabled() {
  [[ $(secret_store_bao "$1" list -format=json | yq -p json -o yaml "has(\"$2/\")") == true ]]
}

# Where Workloads' secrets live, at lab/workloads/<workload>/<key>, and the Platform's
# own, at lab/platform/.
secret_store_has_kv_mount() { bao_enabled secrets lab 2>/dev/null; }
fix_secret_store_has_kv_mount() {
  changed "Creating the KV v2 mount lab/"
  quietly secret_store_bao secrets enable -path=lab -version=2 kv
}

# secret_store_bao <bao arguments>: the bao CLI as the Secret Store's root. It runs
# inside the Secret Store's container, so the Host needs no bao of its own.
secret_store_bao() {
  [[ -f $SECRET_STORE_INIT ]] || die "the Secret Store isn't set up yet; run 'just host setup'"
  secret_store_running || die "the Secret Store isn't running; run 'just start'"
  # Passed by name, so the token never shows up in the Host's process list.
  BAO_TOKEN=$(yq -p json -o yaml '.root_token' "$SECRET_STORE_INIT") \
    podman exec -i -e BAO_TOKEN "$SECRET_STORE_UNIT" bao "$@"
}

# Single sign-on's secrets (ADR 0013): the Lab login's password and each OIDC client's
# secret, at lab/platform/sso/. Generated once and never changed, so the Lab login
# survives every Lab. Which ones, sso.sh reads from Dex's config, so a new client
# there gets its secret at the next `just host setup`.
DEX_CONFIG=$LAB_ROOT/platform/dex/config.yaml

# sso_secret_read <path under lab/>: prints that secret as `bao kv get -format=json`
# does, or nothing if the Secret Store has none there. Fails if the Secret Store can't
# say, which must not read as "none": the next step would generate it again.
sso_secret_read() {
  local out status=0
  # Never from stdin, which is the caller's list of secrets.
  out=$(secret_store_bao kv get -mount=lab -format=json "$1" 2>&1 </dev/null) || status=$?
  sso_secret_answer "$status" <<<"$out"
}

# sso_secrets_missing: prints "<path under lab/> <field>..." for each of single
# sign-on's secrets that lacks fields in the Secret Store, one per line. Fails if it
# can't tell.
sso_secrets_missing() {
  local wanted path fields secret missing
  wanted=$(sso_secrets <"$DEX_CONFIG") || return
  while read -r path fields; do
    secret=$(sso_secret_read "$path") || return
    # shellcheck disable=SC2086 # one argument per field.
    missing=$(sso_missing_fields $fields <<<"$secret") || return
    # shellcheck disable=SC2086 # on one line.
    [[ -z $missing ]] || echo "$path" $missing
  done <<<"$wanted"
}

sso_secrets_exist() {
  local missing
  missing=$(sso_secrets_missing 2>/dev/null) && [[ -z $missing ]]
}
fix_sso_secrets_exist() {
  local missing path fields
  missing=$(sso_secrets_missing) || die "can't read single sign-on's secrets from the Secret Store"
  # Nothing, when the check only failed for want of an answer: the loop would still
  # read one empty line.
  [[ -n $missing ]] || return 0
  while read -r path fields; do
    changed "Generating lab/$path ($fields) in the Secret Store"
    # shellcheck disable=SC2086 # one argument per field.
    sso_secret_generate "$path" $fields
  done <<<"$missing"
}

# sso_secret_generate <path under lab/> <field>...: gives that secret a random value
# for each of those fields, and leaves its others alone. The write names the version it
# read (-cas), so it never replaces a value, even one written since. The values go to
# bao on stdin: an argument would show up in the Host's process list.
sso_secret_generate() {
  local path=$1 version write=patch field
  shift
  version=$(sso_secret_read "$path" | sso_secret_version) || die "can't read lab/$path from the Secret Store"
  ((version > 0)) || write=put
  # 32 hex characters, which is also a length oauth2-proxy takes for its cookie secret.
  for field; do printf '%s\t%s\n' "$field" "$(openssl rand -hex 16)"; done |
    jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add' |
    quietly secret_store_bao kv "$write" -mount=lab -cas="$version" "$path" -
}

# secret_store_trust_lab: makes the Lab and the Secret Store trust each other. ESO reads
# secrets with Kubernetes auth (platform/external-secrets/values.yaml), and every Lab
# has a new API CA, so the auth is pointed at it here. OpenBao keeps no token of the
# Lab's: it checks each login's token with a TokenReview made with that same token.
# ESO, in turn, trusts the Secret Store's certificate through the Lab CA.
secret_store_trust_lab() {
  local eso_ns eso_audience spec role service_account part
  need_lab
  log "Pointing the Secret Store's Kubernetes auth at the Lab"
  bao_enabled auth kubernetes || quietly secret_store_bao auth enable kubernetes
  eso_ns=$(component_namespace platform/external-secrets)
  eso_audience=$(platform_fact eso.audience) || return
  # Two roles, each read-only and for its own half of the Secret Store: eso for
  # Workloads' secrets, lab/workloads/<workload>/<key>, and eso-platform for the
  # Platform's own, lab/platform/*, which no Workload may read (ADR 0013): the Lab login
  # and the OIDC clients' secrets. Each is bound to a ServiceAccount of its own, so
  # neither reads the other's. That's the ServiceAccount the role's ClusterSecretStore
  # names.
  for spec in "eso workloads" "eso-platform platform"; do
    read -r role part <<<"$spec"
    service_account=$(platform_fact "$role.service-account") || return
    quietly secret_store_bao policy write "$role" - <<EOF
path "lab/data/$part/*" { capabilities = ["read"] }
path "lab/metadata/$part/*" { capabilities = ["read", "list"] }
EOF
    quietly secret_store_bao write "auth/kubernetes/role/$role" \
      bound_service_account_names="$service_account" bound_service_account_namespaces="$eso_ns" \
      audience="$eso_audience" token_policies="$role" token_ttl=1h
  done
  kc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
    base64 -d | quietly secret_store_bao write auth/kubernetes/config \
    kubernetes_host="https://$(lab_server_ip):6443" kubernetes_ca_cert=- disable_local_ca_jwt=true
  # The ClusterSecretStores trust the Secret Store's certificate through this.
  lab_ca_configmap "$eso_ns"
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
  wait_until_none 30 "the Secret Store didn't come back unsealed; see: journalctl --user -u $SECRET_STORE_UNIT" \
    secret_store_sealed
  log "The Secret Store is running again"
}

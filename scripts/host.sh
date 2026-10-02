# The Host's one-time setup (ADRs 0001 and 0003): where it puts things, and every step
# that prepares it, each with a check for "done" and a fix. Sourced after lib.sh by
# host-setup.sh, which fixes the steps (yours as the owner, root's under sudo), and by
# doctor.sh, which reports them. up.sh and verify.sh source it for the Lab CA and the
# Secret Store, and bao.sh and vault-backup.sh for the Secret Store. Each check needs no
# root and no Docker socket.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file
# shellcheck disable=SC2329  # the fix_* and blocked_* functions are called by name

# The Lab's owner, also when host-setup.sh runs under sudo.
LAB_OWNER=${SUDO_USER:-$USER}
LAB_OWNER_HOME=$(getent passwd "$LAB_OWNER" | cut -d: -f6)

# ADR 0001: Docker CE's data directory, on /home because the root volume is small.
DOCKER_DATA_ROOT=/home/docker-data

# ADR 0003: the Lab CA, generated once by host-setup in the owner's home, outside the
# repo, and trusted by the Host through the anchor (Fedora's ca-trust).
LAB_HOST_DIR=$LAB_OWNER_HOME/.local/share/k3d-lab
LAB_CA_DIR=$LAB_HOST_DIR/ca
LAB_CA_CERT=$LAB_CA_DIR/ca.crt
LAB_CA_KEY=$LAB_CA_DIR/ca.key
LAB_CA_ANCHOR=/etc/pki/ca-trust/source/anchors/k3d-lab-ca.crt

# ADR 0003: the Secret Store, OpenBao as a rootless Podman Quadlet of the owner's. All of
# its state lives in SECRET_STORE_DIR, which vault-backup archives: the Raft data, the
# unseal key, the root token, and its TLS certificate from the Lab CA.
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

DOCKER_CE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_DAEMON_JSON=/etc/docker/daemon.json

# Every step, in the order they're done: its check, who fixes it (owner or root), and
# what it means. Each check has a fix_<check>, and may have a blocked_<check> that
# prints why it can't be fixed without you. The order carries the dependencies: root
# trusts the Lab CA only once it exists, and the Secret Store waits for the firewall,
# so it never listens before the LAN is kept out.
HOST_STEPS=(
  lab_ca_exists owner "the Lab CA exists ($LAB_CA_DIR)"
  docker_ce_installed root "Docker CE is installed"
  docker_data_root_labelled root "SELinux labels $DOCKER_DATA_ROOT like /var/lib/docker"
  docker_data_root_set root "Docker CE keeps its data in $DOCKER_DATA_ROOT"
  docker_ce_running root "Docker CE is running and starts at boot"
  owner_in_docker_group root "$LAB_OWNER is in the docker group"
  lab_ca_trusted root "the Host trusts the Lab CA"
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

# What each side runs to fix its steps.
host_setup_command() {
  case $1 in
    owner) echo "just host-setup" ;;
    root) echo "sudo scripts/host-setup.sh" ;;
  esac
}

# blocked_reason <check>: prints why that step can't be fixed without you, and succeeds,
# if it can't.
blocked_reason() { declare -F "blocked_$1" >/dev/null && "blocked_$1"; }

# report_host_steps: one line per step, for doctor. Changes nothing.
report_host_steps() {
  local i check reason
  for ((i = 0; i < ${#HOST_STEPS[@]}; i += 3)); do
    check=${HOST_STEPS[i]}
    if reason=$(blocked_reason "$check"); then
      fail "$reason"
    elif "$check"; then
      ok "${HOST_STEPS[i + 2]}"
    else
      warn "not yet: ${HOST_STEPS[i + 2]} (run '$(host_setup_command "${HOST_STEPS[i + 1]}")')"
    fi
  done
}

# fix_host_steps <owner|root>: goes through the steps in order and fixes that side's,
# checking each again after its fix. Stops at the first step that isn't done and
# belongs to the other side, and after its own last step. Changes nothing if any of
# its steps is blocked.
fix_host_steps() {
  local side=$1 i last=-1 check who description reason
  for ((i = 0; i < ${#HOST_STEPS[@]}; i += 3)); do
    [[ ${HOST_STEPS[i + 1]} != "$side" ]] || last=$i
  done
  for ((i = 0; i <= last; i += 3)); do
    [[ ${HOST_STEPS[i + 1]} == "$side" ]] || continue
    if reason=$(blocked_reason "${HOST_STEPS[i]}"); then die "$reason"; fi
  done
  for ((i = 0; i <= last; i += 3)); do
    check=${HOST_STEPS[i]} who=${HOST_STEPS[i + 1]} description=${HOST_STEPS[i + 2]}
    if ! "$check"; then
      if [[ $who != "$side" ]]; then
        warn "not yet: $description"
        die "the next step needs $who: run '$(host_setup_command "$who")' yourself, then '$(host_setup_command "$side")' again"
      fi
      "fix_$check"
      "$check" || die "fixed, but still not done: $description"
    fi
    ok "$description"
  done
}

# Counts what fix_host_steps changed, so a run with nothing to do can say so.
changes=0
changed() {
  log "$1"
  changes=$((changes + 1))
}

# Installs whichever of the given packages are missing. Root only.
dnf_install() {
  local pkg absent=()
  for pkg; do rpm -q "$pkg" >/dev/null 2>&1 || absent+=("$pkg"); done
  ((${#absent[@]} == 0)) || dnf -y install "${absent[@]}"
}

# Both halves: the Lab loads the key into cert-manager, and the Host trusts the certificate.
lab_ca_exists() { [[ -f $LAB_CA_CERT && -f $LAB_CA_KEY ]]; }
blocked_lab_ca_exists() {
  [[ -e $LAB_CA_CERT || -e $LAB_CA_KEY ]] && ! lab_ca_exists &&
    echo "only half of the Lab CA is in $LAB_CA_DIR; restore the other half, or delete both to start over (everything it signed must then be trusted again)"
}
fix_lab_ca_exists() {
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
}

docker_ce_installed() { rpm -q "${DOCKER_CE_PACKAGES[@]}" >/dev/null 2>&1; }
fix_docker_ce_installed() {
  changed "Installing Docker CE"
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] ||
    dnf -y config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
  dnf_install "${DOCKER_CE_PACKAGES[@]}"
}

# SELinux labels the data directory as it would /var/lib/docker.
docker_data_root_labelled() {
  ! selinuxenabled 2>/dev/null ||
    [[ $(matchpathcon -n "$DOCKER_DATA_ROOT") == "$(matchpathcon -n /var/lib/docker)" ]]
}
fix_docker_data_root_labelled() {
  changed "Labelling $DOCKER_DATA_ROOT like /var/lib/docker for SELinux"
  dnf_install policycoreutils-python-utils
  semanage fcontext -a -e /var/lib/docker "$DOCKER_DATA_ROOT"
  [[ ! -d $DOCKER_DATA_ROOT ]] || restorecon -R "$DOCKER_DATA_ROOT"
}

# Docker CE keeps its data on /home, because the root volume is small (ADR 0001).
docker_data_root_set() {
  grep -Eq "\"data-root\": *\"$DOCKER_DATA_ROOT\"" "$DOCKER_DAEMON_JSON" 2>/dev/null
}
blocked_docker_data_root_set() {
  [[ -f $DOCKER_DAEMON_JSON ]] && ! docker_data_root_set &&
    echo "$DOCKER_DAEMON_JSON exists without data-root $DOCKER_DATA_ROOT: add it by hand, then re-run"
}
# daemon.json is written last, so a run that fails partway resumes here: rsync picks
# up where it stopped.
fix_docker_data_root_set() {
  changed "Moving Docker CE's data to $DOCKER_DATA_ROOT"
  systemctl stop docker.socket docker 2>/dev/null || true
  if [[ -d /var/lib/docker ]]; then
    # Anything Docker already stored moves with it. The old directory is kept until you
    # delete it yourself, and it's never pruned: it may hold images nothing else has.
    dnf_install rsync
    local need free
    need=$(du -sx --block-size=1 /var/lib/docker | cut -f1)
    [[ ! -d $DOCKER_DATA_ROOT ]] || need=$((need - $(du -sx --block-size=1 "$DOCKER_DATA_ROOT" | cut -f1)))
    free=$(df --output=avail --block-size=1 /home | tail -1)
    ((free > need + 20 * 1024 ** 3)) || die "/home needs $((need / 1024 ** 3)) GiB plus 20 GiB free for the move"
    # -X keeps overlay2's trusted.* xattrs, -A ACLs, -H hardlinks, -S sparse files.
    rsync -aHAXS --numeric-ids /var/lib/docker/ "$DOCKER_DATA_ROOT/"
    mv /var/lib/docker /var/lib/docker.pre-move
    log "The old data is in /var/lib/docker.pre-move; once the Lab works, free it with: sudo rm -rf /var/lib/docker.pre-move"
  fi
  install -d -m 0710 "$DOCKER_DATA_ROOT"
  restorecon -R "$DOCKER_DATA_ROOT"
  install -d /etc/docker
  printf '{\n  "data-root": "%s"\n}\n' "$DOCKER_DATA_ROOT" >"$DOCKER_DAEMON_JSON"
}

docker_ce_running() { systemctl -q is-enabled docker && systemctl -q is-active docker; }
fix_docker_ce_running() {
  changed "Starting Docker CE and enabling it at boot"
  systemctl enable --now docker
}

# in_docker_group [user]: without a user, whether this login session is.
# The group lets the owner run k3d and docker without sudo. It's root-equivalent.
in_docker_group() { [[ " $(id -nG "$@") " == *" docker "* ]]; }
owner_in_docker_group() { in_docker_group "$LAB_OWNER"; }
fix_owner_in_docker_group() {
  changed "Adding $LAB_OWNER to the docker group (root-equivalent; takes effect at the next login)"
  usermod -aG docker "$LAB_OWNER"
}

# In the bundle curl and browsers read, which update-ca-trust extracts from the anchors.
lab_ca_trusted() {
  openssl verify -CAfile /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem "$LAB_CA_CERT" >/dev/null 2>&1
}
fix_lab_ca_trusted() {
  changed "Adding the Lab CA to the Host's trust store"
  install -m 0644 "$LAB_CA_CERT" "$LAB_CA_ANCHOR"
  update-ca-trust extract
}

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
    echo "$SECRET_STORE_DATA exists, but its unseal key doesn't; restore $SECRET_STORE_UNSEAL_KEY from a vault-backup, or delete $SECRET_STORE_DIR to start over (its secrets are lost)"
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
}
secret_store_config_current() { [[ -f $SECRET_STORE_CONFIG && $(<"$SECRET_STORE_CONFIG") == "$(secret_store_config)" ]]; }
fix_secret_store_config_current() {
  changed "Writing the Secret Store's configuration"
  secret_store_config >"$SECRET_STORE_CONFIG"
}

# keep-id maps the owner to the image's openbao user (100:1000), so the owner owns
# every file OpenBao writes, and vault-backup can read them.
secret_store_quadlet() {
  cat <<EOF
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

# Once ever. The root token never leaves the Host; scripts/bao.sh uses it.
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
  [[ $("$LAB_ROOT/scripts/bao.sh" "$1" list -format=json | yq -p json -o yaml "has(\"$2/\")") == true ]]
}

# Where Workloads' secrets live: lab/workloads/<workload>/<key>.
secret_store_has_kv_mount() { bao_enabled secrets lab 2>/dev/null; }
fix_secret_store_has_kv_mount() {
  changed "Creating the KV v2 mount lab/"
  quietly "$LAB_ROOT/scripts/bao.sh" secrets enable -path=lab -version=2 kv
}

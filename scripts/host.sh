# The Host's one-time setup (ADRs 0001 and 0003): where it puts things, and what "done"
# means for each step. Sourced after lib.sh by host-setup.sh and doctor.sh, which check
# these as the owner, and by host-setup-root.sh, which fixes the ones that need root.
# up.sh and verify.sh source it for the Lab CA and the Secret Store, and bao.sh and
# vault-backup.sh for the Secret Store. Sharing them keeps them agreeing on what's left
# to do. Each check needs no root and no Docker socket.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

# The Lab's owner, also when host-setup-root.sh runs under sudo.
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

# The steps that need root, in the order host-setup-root.sh does them: a check, then
# what it means. Scripts go through them with run_root_steps.
ROOT_STEPS=(
  docker_ce_installed "Docker CE is installed"
  docker_data_root_labelled "SELinux labels $DOCKER_DATA_ROOT like /var/lib/docker"
  docker_data_root_set "Docker CE keeps its data in $DOCKER_DATA_ROOT"
  docker_ce_running "Docker CE is running and starts at boot"
  owner_in_docker_group "$LAB_OWNER is in the docker group"
  lab_ca_trusted "the Host trusts the Lab CA"
  secret_store_firewalled "only the Lab's subnet can reach the Secret Store's port $SECRET_STORE_PORT"
)

# run_root_steps <on_fail>: prints OK for each step that's done, and calls
# on_fail <check> <description> for each that isn't.
run_root_steps() {
  local i
  for ((i = 0; i < ${#ROOT_STEPS[@]}; i += 2)); do
    if "${ROOT_STEPS[i]}"; then
      ok "${ROOT_STEPS[i + 1]}"
    else
      "$1" "${ROOT_STEPS[i]}" "${ROOT_STEPS[i + 1]}"
    fi
  done
}

# Counts what a setup script changed, so a run with nothing to do can say so.
changes=0
changed() {
  log "$1"
  changes=$((changes + 1))
}

docker_ce_installed() { rpm -q "${DOCKER_CE_PACKAGES[@]}" >/dev/null 2>&1; }

docker_ce_running() { systemctl -q is-enabled docker && systemctl -q is-active docker; }

# Docker CE keeps its data on /home, because the root volume is small (ADR 0001).
docker_data_root_set() {
  grep -Eq "\"data-root\": *\"$DOCKER_DATA_ROOT\"" "$DOCKER_DAEMON_JSON" 2>/dev/null
}

# SELinux labels the data directory as it would /var/lib/docker.
docker_data_root_labelled() {
  ! selinuxenabled 2>/dev/null ||
    [[ $(matchpathcon -n "$DOCKER_DATA_ROOT") == "$(matchpathcon -n /var/lib/docker)" ]]
}

# in_docker_group [user]: without a user, whether this login session is.
# The group lets the owner run k3d and docker without sudo. It's root-equivalent.
in_docker_group() { [[ " $(id -nG "$@") " == *" docker "* ]]; }
owner_in_docker_group() { in_docker_group "$LAB_OWNER"; }

# Both halves: the Lab loads the key into cert-manager, and the Host trusts the certificate.
lab_ca_exists() { [[ -f $LAB_CA_CERT && -f $LAB_CA_KEY ]]; }

# In the bundle curl and browsers read, which update-ca-trust extracts from the anchors.
lab_ca_trusted() {
  openssl verify -CAfile /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem "$LAB_CA_CERT" >/dev/null 2>&1
}

# In the running firewall. Only root can query the permanent configuration without
# polkit asking for a password, but host-setup-root.sh writes it there and reloads.
secret_store_firewalled() {
  local rule
  for rule in "${SECRET_STORE_FIREWALL_RULES[@]}"; do
    firewall-cmd -q --policy "$SECRET_STORE_FIREWALL_POLICY" --query-rich-rule "$rule" 2>/dev/null || return 1
  done
}

# The Secret Store's own state, as the owner sees it. These need its user systemd, so
# they're for the owner's scripts, never host-setup-root.sh.
secret_store_installed() { [[ -f $SECRET_STORE_QUADLET ]]; }
secret_store_running() { systemctl --user -q is-active "$SECRET_STORE_UNIT"; }

# bao_status: `bao status` in the container, as JSON. Exits 0 if unsealed, 2 if sealed
# or not initialised yet, and 1 if OpenBao doesn't answer.
bao_status() {
  podman exec "$SECRET_STORE_UNIT" bao status -format=json 2>/dev/null
}
secret_store_unsealed() { bao_status >/dev/null; }
# bao_enabled <secrets|auth> <path>: whether that secrets engine or auth method is
# enabled at <path>/.
bao_enabled() {
  [[ $("$LAB_ROOT/scripts/bao.sh" "$1" list -format=json | yq -p json -o yaml "has(\"$2/\")") == true ]]
}
secret_store_answers() {
  local status=0
  bao_status >/dev/null || status=$?
  ((status != 1))
}

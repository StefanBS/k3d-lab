# The Host's one-time setup (ADRs 0001 and 0003): where it puts things, and what "done"
# means for each step. Sourced after lib.sh by host-setup.sh and doctor.sh, which check
# these as the owner, and by host-setup-root.sh, which fixes the ones that need root.
# Sharing them keeps them agreeing on what's left to do. Each check needs no root and
# no Docker socket.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file

# The Lab's owner, also when host-setup-root.sh runs under sudo.
LAB_OWNER=${SUDO_USER:-$USER}

# ADR 0001: Docker CE's data directory, on /home because the root volume is small.
DOCKER_DATA_ROOT=/home/docker-data

# ADR 0003: the Lab CA, generated once by host-setup in the owner's home, outside the
# repo, and trusted by the Host through the anchor (Fedora's ca-trust).
LAB_CA_DIR=$(getent passwd "$LAB_OWNER" | cut -d: -f6)/.local/share/k3d-lab/ca
LAB_CA_CERT=$LAB_CA_DIR/ca.crt
LAB_CA_KEY=$LAB_CA_DIR/ca.key
LAB_CA_ANCHOR=/etc/pki/ca-trust/source/anchors/k3d-lab-ca.crt

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

# In the bundle curl and browsers read, which update-ca-trust extracts from the anchors.
lab_ca_trusted() {
  openssl verify -CAfile /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem "$LAB_CA_CERT" >/dev/null 2>&1
}

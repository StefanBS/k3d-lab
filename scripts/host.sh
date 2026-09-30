# The Host's one-time setup (ADRs 0001 and 0003): what "done" means for each step.
# Sourced after lib.sh by host-setup.sh and doctor.sh, which check these as the owner,
# and by host-setup-root.sh, which fixes the ones that need root. Sharing them keeps
# them agreeing on what's left to do. Each check needs no root and no Docker socket.
# shellcheck shell=bash

DOCKER_CE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# podman-docker declares Conflicts: docker-ce (ADR 0001), and these come with it.
# Rootless Podman itself stays.
PODMAN_DOCKER_PACKAGES=(podman-docker docker-compose docker-compose-switch moby-filesystem)
DOCKER_DAEMON_JSON=/etc/docker/daemon.json
CA_TRUST_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# Counts what a setup script changed, so a run with nothing to do can say so.
changes=0
changed() {
  log "$1"
  changes=$((changes + 1))
}

# The ones of PODMAN_DOCKER_PACKAGES that are installed, one per line.
podman_docker_installed() {
  rpm -q --qf '%{NAME}\n' "${PODMAN_DOCKER_PACKAGES[@]}" 2>/dev/null | grep -v 'not installed'
}
podman_docker_removed() { [[ -z $(podman_docker_installed) ]]; }

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

# The group lets the owner run k3d and docker without sudo. It's root-equivalent.
in_docker_group() { id -nG "$1" | tr ' ' '\n' | grep -qx docker; }

# Anchored, and in the bundle curl and browsers read, which update-ca-trust extracts.
# Not a pipe into grep -q: with pipefail, tr's SIGPIPE would make it fail at random.
lab_ca_trusted() {
  cmp -s "$LAB_CA_CERT" "$LAB_CA_ANCHOR" &&
    grep -qF "$(sed '/-----/d' "$LAB_CA_CERT" | tr -d '\n')" <(tr -d '\n' <"$CA_TRUST_BUNDLE")
}

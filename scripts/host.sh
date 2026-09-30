# The Host's one-time setup (ADRs 0001 and 0003): what "done" means for each step.
# Sourced after lib.sh by host-setup.sh and doctor.sh, which check these as the owner,
# and by host-setup-root.sh, which fixes the ones that need root. Sharing them keeps
# them agreeing on what's left to do. Each needs no root and no Docker socket.
# shellcheck shell=bash

DOCKER_CE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_DAEMON_JSON=/etc/docker/daemon.json

# podman-docker declares Conflicts: docker-ce (ADR 0001). Rootless Podman itself stays.
podman_docker_removed() { ! rpm -q podman-docker >/dev/null 2>&1; }

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

lab_ca_trusted() { cmp -s "$LAB_CA_CERT" "$LAB_CA_ANCHOR"; }

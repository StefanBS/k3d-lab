#!/usr/bin/env bash
# The Host setup steps that need root. You run this yourself, never a recipe:
#   sudo scripts/host-setup-root.sh
# Every step checks first and changes nothing if it's already done, so it's safe to re-run.
# Run `just host-setup` before and after it: that does the rest and says what's left.

[[ $EUID -eq 0 && -n ${SUDO_USER:-} ]] || {
  echo "error: run this with sudo, as the Lab's owner: sudo $0" >&2
  exit 1
}
owner=$SUDO_USER
# lib.sh finds the Lab CA in the owner's home, not root's.
HOME=$(getent passwd "$owner" | cut -d: -f6)
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

changes=0
changed() {
  log "$1"
  changes=$((changes + 1))
}

# Installs whichever of the given packages are missing.
dnf_install() {
  local pkg missing=()
  for pkg; do rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
  ((${#missing[@]} == 0)) || dnf -y install "${missing[@]}"
}

# Fails before changing anything, so a half-done run can't come from this.
[[ -f $LAB_CA_CERT ]] || die "the Lab CA doesn't exist yet: run 'just host-setup' as $owner first"
if [[ -f $DOCKER_DAEMON_JSON ]] && ! docker_data_root_set; then
  die "$DOCKER_DAEMON_JSON exists without data-root $DOCKER_DATA_ROOT: add it by hand, then re-run"
fi

if podman_docker_removed; then
  ok "podman-docker isn't installed"
else
  changed "Removing podman-docker, which conflicts with docker-ce (Podman itself stays)"
  mapfile -t conflicting < <(rpm -q --qf '%{NAME}\n' podman-docker docker-compose docker-compose-switch moby-filesystem 2>/dev/null | grep -v 'not installed')
  dnf -y remove "${conflicting[@]}"
fi

# podman-docker's symlink to rootful Podman's socket; Docker CE creates a real one.
if [[ -L /var/run/docker.sock ]]; then
  changed "Removing the /var/run/docker.sock symlink podman-docker left"
  rm /var/run/docker.sock
fi

if docker_ce_installed; then
  ok "Docker CE is installed"
else
  changed "Installing Docker CE"
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] ||
    dnf -y config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
  dnf_install "${DOCKER_CE_PACKAGES[@]}"
fi

if docker_data_root_labelled; then
  ok "SELinux labels $DOCKER_DATA_ROOT like /var/lib/docker"
else
  changed "Labelling $DOCKER_DATA_ROOT like /var/lib/docker for SELinux"
  dnf_install policycoreutils-python-utils
  semanage fcontext -a -e /var/lib/docker "$DOCKER_DATA_ROOT"
  [[ ! -d $DOCKER_DATA_ROOT ]] || restorecon -R "$DOCKER_DATA_ROOT"
fi

if docker_data_root_set; then
  ok "Docker CE keeps its data in $DOCKER_DATA_ROOT"
else
  changed "Moving Docker CE's data to $DOCKER_DATA_ROOT"
  [[ ! -e $DOCKER_DATA_ROOT ]] || die "$DOCKER_DATA_ROOT already exists but Docker CE doesn't use it: move it aside first"
  systemctl stop docker.socket docker 2>/dev/null || true
  if [[ -d /var/lib/docker ]]; then
    # Anything Docker already stored moves with it. The old directory is kept until you
    # delete it yourself, and it's never pruned: it may hold images nothing else has.
    dnf_install rsync
    need=$(du -sx --block-size=1 /var/lib/docker | cut -f1)
    free=$(df --output=avail --block-size=1 /home | tail -1)
    ((free > need + 20 * 1024 ** 3)) || die "/home needs $((need / 1024 ** 3)) GiB plus 20 GiB free for the move"
    # -X keeps overlay2's trusted.* xattrs, -A ACLs, -H hardlinks, -S sparse files.
    rsync -aHAXS --numeric-ids /var/lib/docker/ "$DOCKER_DATA_ROOT/"
    mv /var/lib/docker /var/lib/docker.pre-move
    log "The old data is in /var/lib/docker.pre-move; once the Lab works, free it with: sudo rm -rf /var/lib/docker.pre-move"
  else
    install -d -m 0710 "$DOCKER_DATA_ROOT"
  fi
  restorecon -R "$DOCKER_DATA_ROOT"
  install -d /etc/docker
  printf '{\n  "data-root": "%s"\n}\n' "$DOCKER_DATA_ROOT" >"$DOCKER_DAEMON_JSON"
fi

if docker_ce_running; then
  ok "Docker CE is running and starts at boot"
else
  changed "Starting Docker CE and enabling it at boot"
  systemctl enable --now docker
fi

if in_docker_group "$owner"; then
  ok "$owner is in the docker group"
else
  changed "Adding $owner to the docker group (root-equivalent; takes effect at the next login)"
  usermod -aG docker "$owner"
fi

if lab_ca_trusted; then
  ok "the Host trusts the Lab CA"
else
  changed "Adding the Lab CA to the Host's trust store"
  install -m 0644 "$LAB_CA_CERT" "$LAB_CA_ANCHOR"
  update-ca-trust extract
fi

if ((changes == 0)); then
  log "Nothing to change: the Host's root steps are already done"
else
  log "Made $changes change(s). Now run 'just host-setup' again as $owner"
fi

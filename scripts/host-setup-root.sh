#!/usr/bin/env bash
# The Host setup steps that need root. You run this yourself, never a recipe:
#   sudo scripts/host-setup-root.sh
# Every step checks first and changes nothing if it's already done, so it's safe to re-run.
# Run `just host-setup` before and after it: that does the rest and says what's left.

[[ $EUID -eq 0 && -n ${SUDO_USER:-} ]] || {
  echo "error: run this with sudo, as the Lab's owner: sudo $0" >&2
  exit 1
}
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

# Installs whichever of the given packages are missing.
dnf_install() {
  local pkg missing=()
  for pkg; do rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
  ((${#missing[@]} == 0)) || dnf -y install "${missing[@]}"
}

# Fails before changing anything, so a half-done run can't come from this.
[[ -f $LAB_CA_CERT ]] || die "the Lab CA doesn't exist yet: run 'just host-setup' as $LAB_OWNER first"
if [[ -f $DOCKER_DAEMON_JSON ]] && ! docker_data_root_set; then
  die "$DOCKER_DAEMON_JSON exists without data-root $DOCKER_DATA_ROOT: add it by hand, then re-run"
fi

# Each fix_<check> does one step of ROOT_STEPS (host.sh), and says what it changes.

fix_docker_ce_installed() {
  changed "Installing Docker CE"
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] ||
    dnf -y config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
  dnf_install "${DOCKER_CE_PACKAGES[@]}"
}

fix_docker_data_root_labelled() {
  changed "Labelling $DOCKER_DATA_ROOT like /var/lib/docker for SELinux"
  dnf_install policycoreutils-python-utils
  semanage fcontext -a -e /var/lib/docker "$DOCKER_DATA_ROOT"
  [[ ! -d $DOCKER_DATA_ROOT ]] || restorecon -R "$DOCKER_DATA_ROOT"
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

fix_docker_ce_running() {
  changed "Starting Docker CE and enabling it at boot"
  systemctl enable --now docker
}

fix_owner_in_docker_group() {
  changed "Adding $LAB_OWNER to the docker group (root-equivalent; takes effect at the next login)"
  usermod -aG docker "$LAB_OWNER"
}

fix_lab_ca_trusted() {
  changed "Adding the Lab CA to the Host's trust store"
  install -m 0644 "$LAB_CA_CERT" "$LAB_CA_ANCHOR"
  update-ca-trust extract
}

fix() { "fix_$1"; }
run_root_steps fix

if ((changes == 0)); then
  log "Nothing to change: the Host's root steps are already done"
else
  log "Made $changes change(s). Now run 'just host-setup' again as $LAB_OWNER"
fi

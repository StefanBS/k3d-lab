# The Host's one-time setup (ADRs 0001 and 0003): where it puts things, and every step
# that prepares it, each with a check for "done" and a fix. Sourced after lib.sh by
# host-setup.sh, which fixes the steps (yours as the owner, root's under sudo), and by
# doctor.sh, which reports them. up.sh and verify.sh source it for the Lab CA. The
# Secret Store's own steps are in secret-store.sh, which adds them to HOST_STEPS when
# it's sourced after this file. Each check needs no root and no Docker socket.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables here are used by the scripts that source this file
# shellcheck disable=SC2329  # the fix_* and blocked_* functions are called by name

# The Lab's owner, also when host-setup.sh runs under sudo.
LAB_OWNER=${SUDO_USER:-$USER}
LAB_OWNER_HOME=$(getent passwd "$LAB_OWNER" | cut -d: -f6)

# ADR 0001: Docker CE's data directory, on /home because the root volume is small.
DOCKER_DATA_ROOT=/home/docker-data

# ADR 0003: the Lab CA, generated once by `just host setup` in the owner's home, outside the
# repo, and trusted by the Host through the anchor (Fedora's ca-trust).
LAB_HOST_DIR=$LAB_OWNER_HOME/.local/share/k3d-lab
LAB_CA_DIR=$LAB_HOST_DIR/ca
LAB_CA_CERT=$LAB_CA_DIR/ca.crt
LAB_CA_KEY=$LAB_CA_DIR/ca.key
LAB_CA_ANCHOR=/etc/pki/ca-trust/source/anchors/k3d-lab-ca.crt

DOCKER_CE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_DAEMON_JSON=/etc/docker/daemon.json

# Every step, in the order they're done: its check, who fixes it (owner or root), and
# what it means. Each check has a fix_<check>, and may have a blocked_<check> that
# prints why it can't be fixed without you. The order carries the dependencies: root
# trusts the Lab CA only once it exists. secret-store.sh adds the Secret Store's steps
# after these, since its certificate is from the Lab CA.
HOST_STEPS=(
  lab_ca_exists owner "Lab CA exists ($LAB_CA_DIR)"
  docker_ce_installed root "Docker CE is installed"
  docker_data_root_labelled root "SELinux labels $DOCKER_DATA_ROOT like /var/lib/docker"
  docker_data_root_set root "Docker CE keeps its data in $DOCKER_DATA_ROOT"
  docker_ce_running root "Docker CE is running and starts at boot"
  owner_in_docker_group root "$LAB_OWNER is in the docker group"
  lab_ca_trusted root "Host trusts the Lab CA"
)

# What each side runs to fix its steps.
host_setup_command() {
  case $1 in
    owner) echo "just host setup" ;;
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

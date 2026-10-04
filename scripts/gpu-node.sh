#!/usr/bin/env bash
# The GPU Node's half of its lifecycle (ADRs 0002 and 0005). Runs as root on the GPU
# Node, never on the Host: scripts/gpu.sh sends it over SSH stdin, as
#   ssh $GPU_NODE_SSH sudo env KEY=value … bash -s -- <subcommand>
# so it never sources lib.sh. It knows only the GPU Node; every value about the Lab comes
# from the Host in the environment, and the join token on stdin, after this script.
#
# Subcommands:
#   setup <public key>  Creates the k3dlab user that the Host logs in as. Run once, by
#                       hand, with sudo as you (just gpu wizard prints how).
#   join                Joins the current Lab. Reads the token from stdin. Cleans up a
#                       Stale install first, keeping its images unless k3s goes back a
#                       version.
#                       Env: LAB_SUBNET HOST_LAN_IP GPU_NODE_IP SERVER_URL
#                            SERVER_VERSION EVICTION NODE_LABEL NODE_TAINT
#   leave               Stops the agent and its pods and removes Cilium's live state,
#                       keeping the install. Fails, listing them, if anything a Left
#                       GPU Node mustn't have is still here. Env: LAB_SUBNET GPU_NODE_IP
#   purge               Leaves, then removes everything join added. Fails, listing
#                       them, if anything of the join's is still here. Env: LAB_SUBNET
#                       GPU_NODE_IP
#   status              Prints whether the agent runs, and what's on the GPU Node. Only
#                       its first line, agent: running or agent: stopped, is for
#                       scripts/gpu.sh; the rest is for you to read.
#                       Env: LAB_SUBNET GPU_NODE_IP, and LAB_CA_HASH while a Lab exists
# shellcheck disable=SC2329  # main calls the cmd_* functions by name, and they the rest
set -euo pipefail

# The k3s install, as k3s's installer lays it out for an agent.
K3S_BIN=/usr/local/bin/k3s
K3S_SERVICE=k3s-agent
K3S_SERVICE_ENV=/etc/systemd/system/$K3S_SERVICE.service.env
K3S_CONFIG=/etc/rancher/k3s/config.yaml
K3S_KILLALL=/usr/local/bin/k3s-killall.sh
K3S_UNINSTALL=/usr/local/bin/k3s-agent-uninstall.sh
K3S_RUN=/run/k3s
# containerd's image store: its blobs, their unpacked snapshots and the metadata that
# links them, which only work together.
K3S_IMAGES=/var/lib/rancher/k3s/agent/containerd
# Where a Stale install's image store waits while the uninstaller runs. The uninstaller
# removes /var/lib/rancher/k3s but not /var/lib/rancher, which status lists and purge
# removes, so a join that dies here leaves nothing behind that they miss. It must stay
# directly in /var/lib/rancher, the JOIN_PATHS entry that remove_install empties around
# it.
KEPT_IMAGES=/var/lib/rancher/kept-containerd
# What join creates beyond k3s's own install, and its uninstaller leaves (the prototype's
# FINDINGS.md, on branch prototype/gpu-node-join: each was checked to be the join's,
# with no rpm owner).
JOIN_PATHS=(/etc/rancher /var/lib/rancher /var/lib/kubelet /etc/cni /opt/cni)
# Cilium's live state, which neither k3s-killall.sh nor the uninstaller remove. The
# socket-LB links pinned under /sys/fs/bpf/cilium stay attached to this machine's root
# cgroup until they're unpinned.
CILIUM_PINS=(/sys/fs/bpf/cilium /sys/fs/bpf/tc)
CILIUM_CGROUP=/run/cilium/cgroupv2
CILIUM_RUN=/run/cilium
# Kept by every leave and purge: GPU Workloads' model weights, downloaded once.
MODEL_DIR=/var/lib/k3d-lab/models
# The user the Host logs in as, with passwordless sudo (ADR 0002).
AUTOMATION_USER=k3dlab

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
need_env() {
  local name
  for name; do [[ -n ${!name:-} ]] || die "$name isn't set; run this through scripts/gpu.sh"; done
}

installed() { [[ -x $K3S_BIN ]]; }

# Prints the Lab CA hash in the token the install was made with: K10<hash>, the part
# of a k3s token before '::'.
install_ca_hash() {
  [[ -f $K3S_SERVICE_ENV ]] || return 0
  sed -n "s/^K3S_TOKEN=[\"']\?\(K10[0-9a-f]*\)::.*/\1/p" "$K3S_SERVICE_ENV"
}

# none, current (made for the Lab with LAB_CA_HASH) or stale (a Stale install).
install_state() {
  if ! installed; then
    echo none
  elif [[ -n ${LAB_CA_HASH:-} && $(install_ca_hash) == "$LAB_CA_HASH" ]]; then
    echo current
  else
    echo stale
  fi
}

# The NetworkManager connection on the device that holds GPU_NODE_IP, or else the one
# the route to the Host goes out on.
lan_connection() {
  local dev
  if [[ -n ${GPU_NODE_IP:-} ]]; then
    dev=$(ip -4 -o addr show to "$GPU_NODE_IP" | awk '{ print $2; exit }')
  fi
  [[ -n ${dev:-} ]] || dev=$(ip -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
  [[ -n $dev ]] || return 1
  nmcli -g GENERAL.CONNECTION device show "$dev"
}

# The connection's saved routes to LAB_SUBNET, one per line, as nmcli writes them.
saved_routes() {
  nmcli -g ipv4.routes connection show "$1" | sed 's/\\//g; s/, /\n/g' |
    awk -v subnet="$LAB_SUBNET" '$1 == subnet'
}

remove_saved_routes() {
  local route
  while read -r route; do
    [[ -n $route ]] || continue
    nmcli connection modify "$1" -ipv4.routes "$route"
  done < <(saved_routes "$1")
}

# Routes LAB_SUBNET via HOST_LAN_IP on the LAN connection, now and after reboots, in
# place of any route there from an earlier HOST_LAN_IP.
set_route() {
  local connection
  connection=$(lan_connection) || die "can't find the NetworkManager connection for $GPU_NODE_IP"
  remove_saved_routes "$connection"
  nmcli connection modify "$connection" +ipv4.routes "$LAB_SUBNET $HOST_LAN_IP"
  # Saved for the next activation; applied now without reconnecting, in place of any
  # live route NetworkManager added at boot, possibly via an earlier HOST_LAN_IP.
  delete_live_routes
  ip route add "$LAB_SUBNET" via "$HOST_LAN_IP"
  log "Routing $LAB_SUBNET via $HOST_LAN_IP ($connection)"
}

# Every live route to LAB_SUBNET: NetworkManager's from boot, and join's own.
delete_live_routes() {
  while ip route del "$LAB_SUBNET" 2>/dev/null; do :; done
}

remove_route() {
  local connection
  if connection=$(lan_connection 2>/dev/null) && [[ -n $connection ]]; then
    remove_saved_routes "$connection"
  fi
  delete_live_routes
}

# Writes the agent's own config: how it registers, and absolute eviction thresholds,
# since 5% of this machine's large, shared disk is far more than it needs free.
# Succeeds only if the file changed.
write_config() {
  local config
  config=$(
    cat <<EOF
# Written by k3d-lab's 'just gpu join'; rewritten at every join.
node-ip: $GPU_NODE_IP
node-label:
  - $NODE_LABEL
node-taint:
  - $NODE_TAINT
kubelet-arg:
  - eviction-hard=nodefs.available<$EVICTION,imagefs.available<$EVICTION
  - eviction-minimum-reclaim=nodefs.available=5Gi,imagefs.available=5Gi
EOF
    if selinux_enabled; then echo "selinux: true"; fi
  )
  [[ -f $K3S_CONFIG && $(<"$K3S_CONFIG") == "$config" ]] && return 1
  install -d "${K3S_CONFIG%/*}"
  printf '%s\n' "$config" >"$K3S_CONFIG"
}

# Enforcing or permissive. k3s then needs its SELinux policy, and containerd's support.
selinux_enabled() { [[ -f /sys/fs/selinux/enforce ]]; }

# Says whether GPU Workloads can open the GPU's devices as they are, or need the
# devices' groups in supplementalGroups.
report_gpu_devices() {
  local dev mode groups=()
  for dev in /dev/kfd /dev/dri/renderD*; do
    [[ -c $dev ]] || continue
    mode=$(stat -c %a "$dev")
    if (((8#$mode & 8#006) == 8#006)); then
      log "GPU device $dev is world-accessible (mode $mode)"
    else
      groups+=("$(stat -c '%G (GID %g)' "$dev")")
    fi
  done
  [[ -c /dev/kfd ]] || warn "no /dev/kfd here: no AMD GPU for compute"
  ((${#groups[@]} == 0)) ||
    warn "GPU Workloads need supplementalGroups for $(printf '%s\n' "${groups[@]}" | sort -u | paste -sd' ')"
}

# GPU Workloads run as users of their own, so each makes its own folder in the model
# directory: writable to all of them, like /tmp, and sticky, so none can delete
# another's. With SELinux on, containers may write only files labelled for them; a
# relabel would undo that, and every join does it again.
make_model_dir() {
  install -d -m 1777 "$MODEL_DIR"
  if selinux_enabled; then chcon -t container_file_t "$MODEL_DIR"; fi
}

install_k3s() {
  local token=$1 skip_selinux=true policy=skipped
  if selinux_enabled; then
    skip_selinux=false
    policy=installed
  fi
  log "Installing the k3s agent $SERVER_VERSION (SELinux policy: $policy)"
  # Never enabled at boot: a reboot always leaves the GPU Node Left (ADR 0002).
  curl -sfL https://get.k3s.io |
    INSTALL_K3S_VERSION=$SERVER_VERSION INSTALL_K3S_EXEC=agent \
      INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_SKIP_START=true \
      INSTALL_K3S_SKIP_SELINUX_RPM=$skip_selinux \
      K3S_URL=$SERVER_URL K3S_TOKEN=$token sh -s - >/dev/null
  # Skipping the enable also skips the installer's daemon-reload.
  systemctl daemon-reload
}

# What's mounted in k3s's run directory or the kubelet's, one mount point per line.
k3s_mounts() { findmnt -rn -o TARGET | grep -E "^($K3S_RUN|/var/lib/kubelet)(/|\$)"; }
cilium_links() { ip -br link | awk '$1 ~ /^(lxc|cilium_)/ { sub(/@.*/, "", $1); print $1 }'; }
# The xtables tools that are installed, as <save command> <restore command> lines.
xtables_tools() {
  local save
  for save in iptables-save ip6tables-save; do
    if command -v "$save" >/dev/null; then echo "$save ${save/-save/-restore}"; fi
  done
}

# Stops the agent and every container it started, which frees the GPU's VRAM.
stop_agent() {
  if [[ -x $K3S_KILLALL ]]; then
    "$K3S_KILLALL" >/dev/null 2>&1 || true
  else
    systemctl stop "$K3S_SERVICE" 2>/dev/null || true
  fi
  # k3s-killall.sh unmounts what's in it, but leaves containerd's state for the
  # containers it killed. A reboot clears it, so the agent starts fine without it.
  # Only once nothing is mounted there.
  if [[ $(k3s_mounts) != *"$K3S_RUN"* ]]; then rm -rf "$K3S_RUN"; fi
}

clean_cilium() {
  local link table save restore
  # Deleting cilium_host also deletes its veth peer, cilium_net.
  for link in $(cilium_links); do
    ip link del "$link" 2>/dev/null || true
  done
  rm -rf "${CILIUM_PINS[@]}"
  if mountpoint -q "$CILIUM_CGROUP"; then umount "$CILIUM_CGROUP"; fi
  rm -rf "$CILIUM_RUN"
  # Rewrites only the xtables tables, without the CILIUM chains and the jumps to them.
  # firewalld's own nftables table is untouched.
  # A table that fails to restore shows up in status, which leave checks.
  while read -r save restore; do
    for table in filter nat mangle raw; do
      "$save" -t "$table" 2>/dev/null | grep -q CILIUM || continue
      "$save" -t "$table" | grep -v CILIUM | "$restore" -T "$table" || true
    done
  done < <(xtables_tools)
}

never_at_boot() {
  if systemctl -q is-enabled "$K3S_SERVICE" 2>/dev/null; then systemctl disable "$K3S_SERVICE" 2>/dev/null; fi
}

# Whether a Stale install's images can be kept under k3s $SERVER_VERSION. containerd
# migrates its store forward, never back, so not for a downgrade, or for a Stale install
# whose version can't be read.
images_keepable() {
  local old
  [[ -d $K3S_IMAGES ]] || return 1
  old=$("$K3S_BIN" --version 2>/dev/null | awk 'NR == 1 { print $3 }') || true
  if [[ $old != v* ]]; then
    warn "can't read the Stale install's k3s version; removing its images"
    return 1
  fi
  if [[ $(printf '%s\n' "$old" "$SERVER_VERSION" | sort -V | head -1) != "$old" ]]; then
    warn "k3s $SERVER_VERSION is older than the Stale install's $old; removing its images"
    return 1
  fi
}

# Everything except the model directory, the k3dlab user and its key. With
# keep-images, also containerd's image store, moved out of the uninstaller's way and
# back.
remove_install() {
  local keep=${1:-} path
  if [[ $keep == keep-images ]]; then
    rm -rf "$KEPT_IMAGES"
    mv "$K3S_IMAGES" "$KEPT_IMAGES"
  fi
  if [[ -x $K3S_UNINSTALL ]]; then "$K3S_UNINSTALL" >/dev/null 2>&1 || true; fi
  for path in "${JOIN_PATHS[@]}"; do
    if [[ $keep == keep-images && $path == "${KEPT_IMAGES%/*}" ]]; then
      find "$path" -mindepth 1 -maxdepth 1 ! -path "$KEPT_IMAGES" -exec rm -rf {} +
    else
      rm -rf "$path"
    fi
  done
  if [[ $keep == keep-images ]]; then
    install -d "${K3S_IMAGES%/*}"
    mv "$KEPT_IMAGES" "$K3S_IMAGES"
  fi
}

# The things a Left GPU Node must not have, one line each.
live_leftovers() {
  local link pin pids save restore count
  pids=$(pgrep -f "^$K3S_BIN|/var/lib/rancher/k3s/data/" | paste -sd' ') && echo "k3s processes: $pids"
  pids=$(grep -l kubepods /proc/[0-9]*/cgroup 2>/dev/null | cut -d/ -f3 | paste -sd' ') || true
  [[ -z $pids ]] || echo "pod processes: $pids"
  for link in $(cilium_links); do
    echo "Cilium link: $link"
  done
  for pin in "${CILIUM_PINS[@]}"; do [[ ! -e $pin ]] || echo "Cilium BPF pins: $pin"; done
  ! mountpoint -q "$CILIUM_CGROUP" || echo "Cilium cgroup2 mount: $CILIUM_CGROUP"
  [[ ! -e $CILIUM_RUN ]] || echo "Cilium state: $CILIUM_RUN"
  [[ ! -e $K3S_RUN ]] || echo "k3s state: $K3S_RUN"
  while read -r save restore; do
    count=$("$save" 2>/dev/null | grep -c CILIUM) || true
    ((count == 0)) || echo "$save: $count CILIUM lines"
  done < <(xtables_tools)
  k3s_mounts | sed 's/^/k3s mount: /' || true
}

# What purge removes and leave keeps, one line each.
install_leftovers() {
  local path connection
  ! installed || echo "k3s: $("$K3S_BIN" --version 2>/dev/null | head -1)"
  [[ ! -f /etc/systemd/system/$K3S_SERVICE.service ]] || echo "service: $K3S_SERVICE"
  for path in "${JOIN_PATHS[@]}"; do [[ ! -e $path ]] || echo "files: $path"; done
  [[ ! -d $K3S_IMAGES ]] || echo "images: $(du -sh "$K3S_IMAGES" | cut -f1)"
  ip route show "$LAB_SUBNET" | sed 's/^/route: /'
  if connection=$(lan_connection 2>/dev/null) && [[ -n $connection ]]; then
    saved_routes "$connection" | sed "s|^|saved route on '$connection': |"
  fi
}

# What makes this machine not Left, one line each: its agent, or else anything that
# mustn't outlive it. After a purge, also anything join added.
not_left() {
  if systemctl -q is-active "$K3S_SERVICE" 2>/dev/null; then
    echo "the agent is running"
  else
    live_leftovers
  fi
  if systemctl -q is-enabled "$K3S_SERVICE" 2>/dev/null; then echo "$K3S_SERVICE is enabled at boot"; fi
  if [[ $1 == purge ]]; then install_leftovers; fi
}

# check_left leave|purge: the definition of a clean leave or purge, which the Host
# relies on. Fails, listing what's still here.
check_left() {
  local found
  found=$(not_left "$1")
  [[ -z $found ]] || die "the GPU Node still has:
$found"
}

cmd_setup() {
  local pubkey=${1:-} home
  [[ $pubkey == ssh-* ]] || die "usage: gpu-node.sh setup '<the Host's public key>'"
  id "$AUTOMATION_USER" >/dev/null 2>&1 ||
    useradd --create-home --comment 'k3d-lab: the Host joins this GPU Node as it' "$AUTOMATION_USER"
  home=$(getent passwd "$AUTOMATION_USER" | cut -d: -f6)
  install -d -m 700 -o "$AUTOMATION_USER" -g "$AUTOMATION_USER" "$home/.ssh"
  printf '%s\n' "$pubkey" >"$home/.ssh/authorized_keys"
  chown "$AUTOMATION_USER:$AUTOMATION_USER" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
  # With SELinux on, sshd refuses keys without the right label.
  if selinux_enabled; then restorecon -R "$home/.ssh"; fi
  # Join runs k3s's installer as root, so narrower sudo wouldn't narrow anything; the
  # key is the boundary (ADR 0002).
  echo "$AUTOMATION_USER ALL=(ALL) NOPASSWD: ALL" >"/etc/sudoers.d/$AUTOMATION_USER"
  chmod 440 "/etc/sudoers.d/$AUTOMATION_USER"
  visudo -qcf "/etc/sudoers.d/$AUTOMATION_USER"
  log "The Host can log in as $AUTOMATION_USER"
}

cmd_join() {
  local token state
  # First, before anything else can read stdin.
  read -r token || die "no join token on stdin"
  [[ $token == K10*::* ]] || die "the join token isn't a k3s token"
  LAB_CA_HASH=${token%%::*}
  need_env LAB_SUBNET HOST_LAN_IP GPU_NODE_IP SERVER_URL SERVER_VERSION EVICTION NODE_LABEL NODE_TAINT

  state=$(install_state)
  if [[ $state == stale ]]; then
    log "Cleaning up a Stale install from an earlier Lab"
    stop_agent
    clean_cilium
    if images_keepable; then
      log "Keeping its images"
      remove_install keep-images
    else
      remove_install
    fi
  fi

  set_route
  make_model_dir
  report_gpu_devices
  local config_changed=false
  if write_config; then config_changed=true; fi
  [[ $state == current ]] || install_k3s "$token"
  never_at_boot

  if systemctl -q is-active "$K3S_SERVICE"; then
    if [[ $config_changed == true ]]; then
      log "Restarting the agent with its new config"
      systemctl restart "$K3S_SERVICE"
    fi
  else
    log "Starting the agent"
    systemctl start "$K3S_SERVICE"
  fi
}

# What leave and purge both do first.
stop_and_clean() {
  log "Stopping the agent and its pods"
  stop_agent
  log "Removing Cilium's live state"
  clean_cilium
  never_at_boot
}

cmd_leave() {
  stop_and_clean
  check_left leave
}

cmd_purge() {
  need_env LAB_SUBNET
  stop_and_clean
  log "Removing k3s, its images, its files and the route (keeping $MODEL_DIR and $AUTOMATION_USER)"
  remove_install
  remove_route
  check_left purge
}

# Whether a Lab's agent runs here is all this machine can tell; the Lab tells Joined
# from Left (gpu.sh status). The first line is the agent's state, the only one gpu.sh
# reads. Then one line per thing found, for you to read, each prefixed:
#   install: the install, and whether it's for this Lab or a Stale install
#   leftover: live state that mustn't outlive the agent, or the agent enabled at boot
#   installed: what purge removes and leave keeps
cmd_status() {
  need_env LAB_SUBNET
  local state
  state=$(install_state)
  if systemctl -q is-active "$K3S_SERVICE" 2>/dev/null; then
    echo "agent: running"
  else
    echo "agent: stopped"
    live_leftovers | sed 's/^/leftover: /'
  fi
  case $state in
    current) echo "install: for this Lab" ;;
    stale) echo "install: Stale install" ;;
    none) echo "install: none" ;;
  esac
  systemctl -q is-enabled "$K3S_SERVICE" 2>/dev/null && echo "leftover: $K3S_SERVICE is enabled at boot"
  install_leftovers | sed 's/^/installed: /'
}

main() {
  ((EUID == 0)) || die "run as root"
  local cmd=${1:-}
  shift || true
  case $cmd in
    setup | join | leave | purge | status) "cmd_$cmd" "$@" ;;
    *) die "usage: gpu-node.sh setup <public key>|join|leave|purge|status" ;;
  esac
}

# On one line, so that bash, reading this script from stdin, never reads past it: what
# follows on stdin is join's token, not commands.
main "$@"; exit

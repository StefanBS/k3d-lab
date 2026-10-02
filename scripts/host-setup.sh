#!/usr/bin/env bash
# Prepares the Host once (ADRs 0001 and 0003). Safe to re-run: each step checks first,
# and a run with nothing to do says so. The steps are in host.sh.
# Run as the Lab's owner, it does the owner's steps. Under sudo, it does the steps that
# need root, which you run yourself: the owner's run says when.
#   sudo scripts/host-setup.sh

if [[ $EUID -eq 0 && -z ${SUDO_USER:-} ]]; then
  echo "error: run this with sudo, as the Lab's owner: sudo $0" >&2
  exit 1
fi
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

if [[ $EUID -eq 0 ]]; then
  fix_host_steps root
  if ((changes == 0)); then
    log "Nothing to change: the Host's root steps are already done. Now run 'just host-setup' as $LAB_OWNER"
  else
    log "Made $changes change(s). Now run 'just host-setup' again as $LAB_OWNER"
  fi
  exit
fi

# The group database has it, but this login session was started without it.
if owner_in_docker_group && ! in_docker_group; then
  warn "this session isn't in the docker group yet: log in again to use docker and k3d without sudo"
fi
fix_host_steps owner
if ((changes == 0)); then
  log "Nothing to change: the Host is already set up"
else
  log "Made $changes change(s); the Host is set up"
fi

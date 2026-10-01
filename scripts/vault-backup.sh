#!/usr/bin/env bash
# Archives the Secret Store (ADR 0003): its data, its unseal key and its root token,
# everything in SECRET_STORE_DIR. The archive can read every secret, so keep it safe.
# Usage: vault-backup.sh <path>. A directory gets a new archive named by the date and time;
# any other path is the archive itself, which must not exist yet.
# OpenBao stops while it's archived, so the data can't change underneath: a few seconds
# in which the Lab can't read secrets, though the Secrets ESO already made stay.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

(($# == 1)) || die "usage: just vault-backup <directory or archive path>"
archive=$1
[[ ! -d $archive ]] || archive=$archive/k3d-lab-secret-store-$(date +%Y%m%d-%H%M%S).tar.gz
[[ ! -e $archive ]] || die "$archive already exists"
[[ -d $(dirname "$archive") ]] || die "$(dirname "$archive") isn't a directory"
[[ -f $SECRET_STORE_INIT ]] || die "the Secret Store isn't set up yet; run 'just host-setup'"

# Started again however the archiving ends.
restart() {
  systemctl --user start "$SECRET_STORE_UNIT"
  retry 30 secret_store_unsealed || die "the Secret Store didn't come back unsealed; see: journalctl --user -u $SECRET_STORE_UNIT"
  log "The Secret Store is running again"
}
if secret_store_running; then
  log "Stopping the Secret Store"
  systemctl --user stop "$SECRET_STORE_UNIT"
  trap restart EXIT
fi

log "Archiving $SECRET_STORE_DIR to $archive"
(
  umask 077
  tar -czf "$archive" -C "$(dirname "$SECRET_STORE_DIR")" "$(basename "$SECRET_STORE_DIR")"
)

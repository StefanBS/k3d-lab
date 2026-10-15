#!/usr/bin/env bash
# Runs the Secret Store's commands (lib/secret-store.sh, ADR 0003):
#   bao <arguments>  Runs the bao CLI as the Secret Store's root, such as:
#                    kv put -mount=lab workloads/<workload>/<key> <field>=<value>
#                    Reads stdin, for arguments like <field>=-.
#   backup <path>    Archives SECRET_STORE_DIR. A directory gets a new archive named by
#                    the date and time; any other path is the archive itself, which must
#                    not exist yet.
#   trust-lab        Makes the Lab and the Secret Store trust each other.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=lib/host.sh
source "$(dirname "$0")/lib/host.sh"
# shellcheck source=lib/secret-store.sh
source "$(dirname "$0")/lib/secret-store.sh"

main() {
  local cmd=${1:-}
  shift || true
  case $cmd in
    bao) secret_store_bao "$@" ;;
    backup)
      (($# == 1)) || die "usage: just secret-store backup <directory or archive path>"
      secret_store_backup "$1"
      ;;
    trust-lab)
      (($# == 0)) || die "usage: secret-store.sh trust-lab"
      secret_store_trust_lab
      ;;
    *) die "usage: secret-store.sh bao <arguments> | backup <path> | trust-lab" ;;
  esac
}

main "$@"

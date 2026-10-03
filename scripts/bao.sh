#!/usr/bin/env bash
# Runs the bao CLI against the Secret Store, with its root token (ADR 0003). The CLI
# runs inside the Secret Store's container, so the Host needs no bao of its own.
# Usage: bao.sh <bao arguments>, such as: kv put -mount=lab workloads/<workload>/<key> <field>=<value>
# Reads stdin, for arguments like <field>=-.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=host.sh
source "$(dirname "$0")/host.sh"

[[ -f $SECRET_STORE_INIT ]] || die "the Secret Store isn't set up yet; run 'just host setup'"
secret_store_running || die "the Secret Store isn't running; see: systemctl --user status $SECRET_STORE_UNIT"
# Passed by name, so the token never shows up in the Host's process list.
BAO_TOKEN=$(yq -p json -o yaml '.root_token' "$SECRET_STORE_INIT")
export BAO_TOKEN
exec podman exec -i -e BAO_TOKEN "$SECRET_STORE_UNIT" bao "$@"

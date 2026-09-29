#!/usr/bin/env bash
# Static checks that need no Lab. CI runs this on every PR.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit

log "shellcheck"
git ls-files -z --cached --others --exclude-standard '*.sh' | xargs -0 shellcheck --external-sources

log "just --fmt --check"
just --fmt --check

log "Lint passed"

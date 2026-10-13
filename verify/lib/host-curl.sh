#!/usr/bin/env bash
# Usage: host-curl.sh <curl arguments>...
# curl from the Host to one of the Lab's names, failing on an error answer and retrying
# while the Gateway isn't answering yet. --cacert replaces the Host's trust store, so only
# the Lab CA can make it pass. verify.sh exports LAB_CA_CERT.
set -euo pipefail
exec curl -sS --fail --retry 5 --retry-all-errors --retry-delay 2 --cacert "$LAB_CA_CERT" "$@"

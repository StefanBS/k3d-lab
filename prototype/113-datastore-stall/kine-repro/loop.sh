#!/usr/bin/env bash
# Red when kine's compaction batch outlives its timeout during the DELETE (k3d-lab#113).
# Scaled down: 2ms timeout vs a ~5-45ms DELETE, as k3s's 5s vs the Lab's 14s DELETE.
cd "$(dirname "$0")"
[[ -x repro ]] || CGO_ENABLED=1 go build -o repro . || exit 2
out=$(./repro -revs 20000 -keys 100 -timeout "${TIMEOUT:-2ms}" 2>&1)
if grep -q 'level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"' <<<"$out"; then
  echo RED; exit 1
fi
echo GREEN

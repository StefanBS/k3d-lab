#!/usr/bin/env bash
# Lab-level loop for k3d-lab#113: a single k3s Server at the Lab's version, with its disk
# writes throttled, write churn, and compaction every 30s. Red if k3s dies.
# Usage: k3s-load.sh kine|etcd [seconds] [write-bps] [write-iops]
set -uo pipefail
mode=$1 duration=${2:-600} wbps=${3:-2mb} wiops=${4:-40}
name=k3s-113-$mode port=6560
# The block device under Docker's data root, where the Server's volume lives.
dev=$(readlink -f "$(findmnt -no SOURCE -T "$(docker info --format '{{.DockerRootDir}}')")")
dir=$(mktemp -d) kcfg=$dir/kubeconfig
extra=(); [[ $mode == etcd ]] && extra=(--cluster-init)

# The Server's logs outlive it, next to this script, for reading after a red run.
cleanup() { docker logs "$name" >"$(dirname "$0")/$name.log" 2>&1; kill $(jobs -p) 2>/dev/null; docker rm -f "$name" >/dev/null 2>&1; docker volume rm "$name" >/dev/null 2>&1; rm -rf "$dir"; }
trap cleanup EXIT
trap 'exit 3' INT TERM
# A crashed earlier run may have left its Server behind.
docker rm -f "$name" >/dev/null 2>&1; docker volume rm "$name" >/dev/null 2>&1

docker run -d --name "$name" --privileged --tmpfs /run --tmpfs /var/run \
  -p 127.0.0.1:$port:6443 -v "$name":/var/lib/rancher/k3s \
  --device-write-bps "$dev:$wbps" --device-write-iops "$dev:$wiops" \
  rancher/k3s:v1.37.1-k3s1 server "${extra[@]}" --tls-san 127.0.0.1 \
  --disable=traefik,servicelb,metrics-server,local-storage,coredns \
  --kube-apiserver-arg=etcd-compaction-interval=30s >/dev/null || exit 2
echo "$(date +%T) started $name ($mode, writes capped at $wbps, $wiops iops)"

for _ in $(seq 120); do
  docker exec "$name" cat /etc/rancher/k3s/k3s.yaml 2>/dev/null | sed "s#:6443#:$port#" >"$kcfg"
  kubectl --kubeconfig "$kcfg" get --raw /readyz >/dev/null 2>&1 && break
  sleep 2
done
kubectl --kubeconfig "$kcfg" get --raw /readyz >/dev/null 2>&1 || { echo "never ready"; docker logs --tail 20 "$name"; exit 2; }
echo "$(date +%T) ready; churning"

# Churn: 4 workers rewriting 100 KiB ConfigMaps, as the reports controller rewrites reports.
head -c 75000 /dev/urandom | base64 -w0 >"$dir/blob"
for w in 1 2 3 4; do
  ( i=0; while :; do
      kubectl --kubeconfig "$kcfg" create configmap "churn-$w-$((i % 20))" --from-file=blob="$dir/blob" --from-literal=n="$w-$i" \
        --dry-run=client -o yaml | kubectl --kubeconfig "$kcfg" apply --request-timeout=20s -f - >/dev/null 2>&1
      i=$((i + 1)); done ) &
done

start=$SECONDS
while ((SECONDS - start < duration)); do
  sleep 10
  logs=$(docker logs "$name" 2>&1)
  starts=$(grep -c 'msg="Starting k3s v' <<<"$logs")
  slow=$(grep -cE 'Slow SQL|took too long|apply request took' <<<"$logs")
  compacts=$(grep -cE 'COMPACT deleted|compacted|finished scheduled compaction' <<<"$logs")
  rev=$(kubectl --kubeconfig "$kcfg" get --raw /api/v1/namespaces/default/configmaps 2>/dev/null | jq -r .metadata.resourceVersion 2>/dev/null)
  running=$(docker inspect -f '{{.State.Running}}' "$name")
  echo "$(date +%T) +$((SECONDS - start))s running=$running starts=$starts rev=${rev:-?} compactions=$compacts slow=$slow $(grep -oE 'COMPACT deleted [0-9]+ rows from [0-9]+ revisions in [0-9.]+[a-zµ]+|finished scheduled compaction[^"]*took[^"]*' <<<"$logs" | tail -1)"
  if grep -q 'level=fatal' <<<"$logs" || [[ $running != true ]] || ((starts > 1)); then
    docker inspect -f 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$name"
    echo "RED: $(grep -E 'level=fatal|"level":"(fatal|panic)"|^panic|^F[0-9]{4}' <<<"$logs" | tail -1 | cut -c1-300)"
    grep -E 'COMPACT compactRev|Slow SQL: DELETE|"level":"(error|fatal|panic)"|level=error' <<<"$logs" | tail -4 | cut -c1-300
    exit 1
  fi
done
echo "GREEN: k3s survived ${duration}s ($slow slow-request lines)"
grep -E 'Slow SQL|took too long' <<<"$logs" | tail -2 | cut -c1-200

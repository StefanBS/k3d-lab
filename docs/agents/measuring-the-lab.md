# Measuring the Lab

What each number really counts, learned the hard way on #113. Check a measurement's meaning here before it goes into an issue.

## Datastore writes

- **A datastore write is a new revision.** kine bumps one global revision per stored write. Read it from any list, twice, and subtract: `kubectl --context k3d-lab get --raw '/api/v1/namespaces/default/configmaps?limit=1' | jq -r .metadata.resourceVersion`. The Lab took about 176 a minute at rest on 2026-10-09.
- **An API write request may store nothing.** The API server answers an update that changes nothing without writing to the datastore. `apiserver_request_total` and `kyverno_client_queries_total` count requests: Kyverno's ~720 webhook configuration updates an hour stored none. To tell, compare an object's `resourceVersion` before and after.
- **Leases are most of the writes.** Each controller with leader election renews its Lease every few seconds, and every renewal is stored.

## Memory and swap on the Host

- **The Host swaps to zram first.** zram has priority 100, and the swap volume on the disk is used only when zram is full (`swapon --show`). `pswpin` and `pswpout` in `/proc/vmstat` count both, so they don't show how much swap reached the disk. That volume's own line in `/proc/diskstats` does.
- **Major page faults are disk reads.** A cgroup's `pgmajfault` (`memory.stat`) rising with the disk busy means the Host is evicting pages and reading them back: thrashing, whatever the swap numbers say.

## Pressure (PSI)

- **The Host-wide `/proc/pressure/io` is inflated.** It counts a task waiting on io_uring as waiting on I/O, so a terminal that reads through io_uring, such as Ghostty, holds it near 100% with every disk idle. Read a cgroup's own `io.pressure`, `cpu.pressure` and `memory.pressure` instead. The Server's is `/sys/fs/cgroup/system.slice/docker-<container id>.scope/`.
- To find which cgroup carries pressure, compare the `some avg10` of each `io.pressure` under `/sys/fs/cgroup`, from the top down.

## Prometheus

The Lab's Prometheus answers through the API server's service proxy, with no port-forward:

```bash
kubectl --context k3d-lab get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=$(jq -rn --arg q '<PromQL>' '$q|@uri')"
```

`/api/v1/query_range` takes `start`, `end` and `step` the same way. `kyverno_client_queries_total` breaks down Kyverno's API calls by component (`job`), `operation` and `resource_kind`.

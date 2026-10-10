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
- **Name a Node's scope before reading it.** Get its ID with `docker inspect -f '{{.Id}}' k3d-lab-server-0` (or `k3d-lab-agent-0`); the busiest `docker-*.scope` may be either. `memory.max` tells them apart: the Server's cap is larger.
- **A k3d Node's `init` cgroup is containerd.** Inside each Node's scope, `k3s` holds k3s, `init` holds `containerd`, its shims and the entrypoint, and `kubepods` holds the pods. Image pulls and unpacking show as `init`'s writes: 11.5 GB of the 12.9 GB written in a fresh `up`.

## Replaying a run

While `up` or `verify` runs, below records every cgroup's pressure, memory, major faults and disk I/O, and the Host's disks and swap, every 2s, into `~/.local/state/k3d-lab/below/` (`scripts/below.sh`). It keeps a week. Read it with that store's config, which the run writes:

```bash
TZ=UTC below --config ~/.local/state/k3d-lab/below/below.conf replay -t '2026-10-09 10:20:00'
TZ=UTC below --config ~/.local/state/k3d-lab/below/below.conf dump cgroup \
  -b 2026-10-09T10:20:00Z -e 2026-10-09T10:21:00Z -s full_path -F 'docker-.*\.scope/(k3s|init)$' \
  -f datetime full_path pressure.io_some_pct mem.pgmajfault io.wbytes_per_sec -O csv
```

- **Record an experiment with `scripts/below-recorder.sh <PID> &`**, given the experiment's PID, then `wait <PID>`. It records into the same store until that PID exits, compressed and capped, and stops itself. An `up` or `verify` that is running already records.
- **below ignores TERM.** It logs "Stop signal received" and keeps recording, so a plain `kill` leaves it running. Stop a recorder with KILL, and check that it's gone with `pgrep -af 'below .*record'`.
- **below prints local time; k3s logs UTC.** Run it with `TZ=UTC`. `-b` and `-e` also take epoch seconds and `2026-10-09T10:20:00Z`.
- **Pod cgroups are named by UID**, as `kubepods/<QoS class>/pod<UID>`. Match them to pods with `kubectl --context k3d-lab get pods -A -o custom-columns=UID:.metadata.uid,NAME:.metadata.name`.
- **`dump disk` and `dump system`** give the Host's disks and swap. The disk under the k3d Nodes' datastores is the one under Docker's data root (`docker info -f '{{.DockerRootDir}}'`).

## Changing the Server for an experiment

A fresh `up` undoes all of these, so end an experiment with one.

- **k3s flags:** write them to `/etc/rancher/k3s/config.yaml` in the Server, e.g. `kube-apiserver-arg: [etcd-compaction-interval=30s]`, then `docker restart k3d-lab-server-0`. The file lives in the container and survives restarts.
- **k3s's environment** is fixed when the container is created, and k3d's entrypoint hooks (`/bin/k3d-entrypoint-*.sh`) run as child processes, so they can't export to k3s. To set a variable such as `KINE_COMPACT_TIMEOUT` without `up`: move `/bin/k3s` to `/bin/k3s-real`, repoint the `/bin` symlinks that name `k3s` (kubectl, crictl, ctr...) at `k3s-real`, and put a script that exports the variable and `exec`s `/bin/k3s-real "$@"` at `/bin/k3s`.
- **`/run` in a Node is a tmpfs that every restart empties.** A hook that copies the datastore there on start restores the copy on disk, which stopped at the switch: the restart rolls the Lab's state back without an error.

## k3s's logs

- **Save them before `just down`.** It deletes the Server with its logs, and runs 1 and 2 of #113 lost their slow-SQL record this way: `docker logs k3d-lab-server-0 > <file>` first.
- **Compare slow-SQL durations as numbers.** k3s logs them as `duration=1.47s` or `duration=850ms`. Compared as strings, `9.9s` sorts above `30.1s`, which gave run 2 of #113 a wrong maximum.

## Prometheus

The Lab's Prometheus answers through the API server's service proxy, with no port-forward:

```bash
kubectl --context k3d-lab get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=$(jq -rn --arg q '<PromQL>' '$q|@uri')"
```

`/api/v1/query_range` takes `start`, `end` and `step` the same way. `kyverno_client_queries_total` breaks down Kyverno's API calls by component (`job`), `operation` and `resource_kind`.

## Stalling the datastore on purpose

#113's stall reproduces on a running Lab in a minute, without `up`: write about 8 GB of buffered data to the disk under Docker's data root, e.g. `dd if=/dev/zero of=<file> bs=1M count=8192`, while timing writes to the API. Datastore writes stalled for 25–60s in every such run on 2026-10-10.

- **It's the Host's writeback, not raw disk bandwidth.** The same 8 GB written with `oflag=direct` stalled nothing, and the same burst on `/`, another filesystem on the same disk, stalled it just as badly. SQLite's `_synchronous=NORMAL` or `OFF` didn't help; a datastore on tmpfs kept slow SQL under 3s.
- **Judge the datastore by k3s's `Slow SQL` lines, not by API latency.** A write's latency also includes webhooks, whose pods run on the starved Agent, and the client's own stalls on the Host.
- **k3s dies only when a compaction is caught in the stall.** The API server compacts every 5 minutes, so most bursts miss one. For a tighter loop, put `kube-apiserver-arg: [etcd-compaction-interval=30s]` in the Server's `/etc/rancher/k3s/config.yaml` and `docker restart` it; a fresh `up` undoes it.

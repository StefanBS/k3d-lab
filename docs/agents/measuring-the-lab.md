# Measuring the Lab

What each number really counts, learned the hard way on #113. Check a measurement's meaning here before it goes into an issue.

## Datastore writes

- **A datastore write is a new revision.** kine bumps one global revision per stored write. Read it from any list, twice, and subtract: `kubectl --context k3d-lab get --raw '/api/v1/namespaces/default/configmaps?limit=1' | jq -r .metadata.resourceVersion`. The Lab took about 176 a minute at rest on 2026-10-09.
- **An API write request may store nothing.** The API server answers an update that changes nothing without writing to the datastore. `apiserver_request_total` and `kyverno_client_queries_total` count requests: Kyverno's ~720 webhook configuration updates an hour stored none. To tell, compare an object's `resourceVersion` before and after.
- **Leases are most of the writes.** Each controller with leader election renews its Lease every few seconds, and every renewal is stored.

## Memory and swap on the Host

- **The Host swaps to zram first.** zram has priority 100, and the swap volume on the disk is used only when zram is full (`swapon --show`). `pswpin` and `pswpout` in `/proc/vmstat` count both, so they don't show how much swap reached the disk. That volume's own line in `/proc/diskstats` does.
- **Major page faults are disk reads.** A cgroup's `pgmajfault` (`memory.stat`) rising with the disk busy means the Host is evicting pages and reading them back: thrashing, whatever the swap numbers say.
- **A k3d Node at its cap isn't thrashing by that alone.** File pages count against the cap, and the kernel gives them back first. During `up` the Agent sat at its 2560 MiB with 2 GiB of file pages from image pulls and no major faults. It thrashes when `file` in `memory.stat` is near zero and `pgmajfault` climbs by thousands a second (#141); at rest it climbed by under one a second.

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
- **Record a Lab at rest the same way, against a `sleep`:** `sleep 6h & p=$!; scripts/below-recorder.sh $p & wait $p`. Killing the `sleep` ends it early.
- **A long recording pushes out old days.** The store holds 2 GiB at about 4 MB a minute, so some eight hours fill it, and below drops whole days, oldest first. Check `du -sh ~/.local/state/k3d-lab/below/store` before a run of hours.
- **below ignores TERM.** It logs "Stop signal received" and keeps recording, so a plain `kill` leaves it running. Stop a recorder with KILL, and check that it's gone with `pgrep -af 'below .*record'`.
- **below prints local time; k3s logs UTC.** Run it with `TZ=UTC`. `-b` and `-e` also take epoch seconds and `2026-10-09T10:20:00Z`.
- **`mem.pgmajfault` and the `io.*_per_sec` fields are rates per second**, not counts per sample: over 49 minutes they came within 10% of the cgroup's own counters (#141). `io_details.8:0.rbytes_per_sec` gives a cgroup's reads from one disk, here sda, by its `MAJ:MIN` in `lsblk`.
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

#113's stall reproduces on a running Lab in two minutes, without `up`:

```bash
scripts/stall-probe.sh <label> [<burst MiB>] [<probe seconds>]
```

It writes a burst of buffered data, 8 GiB unless told otherwise, to the filesystem under Docker's data root while it writes to the API once a second, and records with below. It appends one row to `~/.local/state/k3d-lab/stall-probe.tsv`, the ledger, and fails when the verdict is red: a slow SQL of 5s or more, a fatal error, or a Server restart. The label names the variant being tested, such as `control`.

- **A table posted to an issue comes from the ledger**, not from scrollback: `column -t -s $'\t' ~/.local/state/k3d-lab/stall-probe.tsv`. Run each variant against a `control` from the same session.
- **It's the Host's writeback, not raw disk bandwidth.** The same 8 GB written with `oflag=direct` stalled nothing, and the same burst on `/`, another filesystem on the same disk, stalled it just as badly. SQLite's `_synchronous=NORMAL` or `OFF` didn't help; a datastore on tmpfs kept slow SQL under 3s.
- **The Host's tuned profile and free memory go with the stall.** On 2026-10-10, under `throughput-performance` (`vm.dirty_ratio` 40, `vm.swappiness` 10), which Fedora's Performance power mode selects, and with under 1 GB free and 7 GB in swap, the slowest slow SQL of a control burst was 6.7–108s. Under `balanced` (`vm.dirty_ratio` 20, `vm.swappiness` 60), with 2–4 GB free, three control bursts logged no slow SQL at all (#144). Both changed at once, so their shares aren't known. Check `tuned-adm active` and `free -m` before blaming anything else: the profile is the owner's choice for the whole desktop, so `just host` doesn't set it and `doctor` doesn't check it.
- **Neither a dirty cap nor another I/O scheduler fixed it.** Under `throughput-performance`, capping `vm.dirty_bytes` at 256 MiB, and `vm.dirty_background_bytes` at 64 MiB, stopped the burst pushing the Host into the swap volume on the disk: 1–2 MB written to it, against 136–703 MB. One such burst still stalled for 30s. Under `balanced` three capped bursts logged no slow SQL, as the controls did. `mq-deadline` or `none` in place of BFQ, on the disk under Docker's data root and under `throughput-performance`, changed neither the swap nor, beyond the drift between runs, the stall; under `balanced`, `mq-deadline` ran only with the cap. So `just host` sets none of them; tuned owns these values, and a sysctl set beside it would fight it.
- **A compaction inside a burst stalls it under any of these.** The one red burst under `balanced`, with the cap and `mq-deadline`, had a compaction start 5s in: it took 8.5s, the slowest slow SQL was 9.2s, and k3s survived (#139).
- **A fresh `up` under `balanced` still logs slow SQL.** With a browser open, it took 8m24s and passed every check, and its slowest slow SQL was 6.9s, over the probe's 5s line, while containerd unpacked images. The fresh `up` before it, under `throughput-performance`, reached 13s.
- **Rotate the variants' order from one pass to the next.** Slow SQL fell from 108s to 3s, though not evenly, over eight bursts under `throughput-performance` whatever the setting, so a control that always runs first can't be told from that drift.
- **Changing a Host setting needs root,** which an agent doesn't have: write the loop as one script, and ask the Lab's owner to run it.
- **The verdict is k3s's `Slow SQL` lines, not API latency.** A write's latency also includes webhooks, whose pods run on the starved Agent, and the client's own stalls on the Host. The ledger records it, as `api_max_s`, only as information.
- **k3s dies only when a compaction is caught in the stall.** The API server compacts every 5 minutes, so most bursts miss one. For a tighter loop, put `kube-apiserver-arg: [etcd-compaction-interval=30s]` in the Server's `/etc/rancher/k3s/config.yaml` and `docker restart` it; a fresh `up` undoes it.

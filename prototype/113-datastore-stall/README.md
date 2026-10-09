# Prototype: the Server's datastore stall (#113)

Throwaway code that answered how k3s dies when its datastore stalls. The findings are on #113; this keeps the loops so a fix can be tested against them.

## `kine-repro/`: kine's compaction crash, in seconds

`kine-repro/loop.sh` runs kine v0.17.1 (the Lab's k3s v1.37.1) on SQLite and compacts with the timeout scaled down to 2ms, below a batch's DELETE. Red when kine exits with:

```
level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"
```

`compact()` gives the transaction a context with `compactTimeout` (5s in k3s) but runs its statements on another context, so a DELETE outlives the deadline, `database/sql` rolls the transaction back, and `MustCommit` exits. Red 10 of 10 runs; green with `TIMEOUT=5s`. Upstream considers this expected on a starved host (k3s-io/kine#790).

## `k3s-load.sh`: a k3s Server under a slow disk

```
./k3s-load.sh kine|etcd [seconds] [write-bps] [write-iops]
```

One k3s Server container at the Lab's version, with writes to Docker's data root throttled (default 2mb/s, 40 iops), four workers rewriting 100 KiB ConfigMaps, and the API server compacting every 30s. Red if k3s exits or restarts; it keeps the Server's log next to itself. Uses port 6560 and about 1 GiB of memory; it doesn't touch the Lab.

Results on 2026-10-09:

| Datastore | Red after | How k3s died |
|---|---|---|
| kine (SQLite) | ~4 min | a compaction DELETE ran 79s, then `Transaction commit failed` |
| etcd (`--cluster-init`) | ~80s, both runs | `slow fdatasync` up to 3.6s, then `"leaderelection lost"` |

A storage stall over about 5s kills k3s on either datastore, so switching to etcd doesn't fix #113: the stall does.

Stopping the script with a task runner's kill skips its cleanup; it removes a crashed run's Server and volume when it starts again.

# Docker CE runs the k3d Nodes, alongside the Host's Podman

The Host already runs rootless Podman, with `podman-docker` providing the `docker` command and `DOCKER_HOST` pointing at Podman's socket. We still install rootful Docker CE for the k3d Nodes. Cilium needs to load eBPF programs, which rootless containers can't do. The GPU Node also needs a container network it can route to, and rootless Podman's pasta networking keeps container IPs inside a private network namespace. Rootful Podman was the other candidate, but k3d calls Podman support experimental, while k3d on Docker is the setup Cilium's guides actually cover.

## Considered Options

- **Rootless Podman**: Cilium can't load eBPF programs there, and the GPU Node can't reach the container network.
- **Rootful Podman**: the socket already exists, but k3d supports Podman only experimentally, and k3d with Cilium is barely tested on it.
- **Plain k3s on the Host**: works, but it gives up k3d's disposable, container-based nodes.

## Consequences

- `podman-docker` is removed, because it conflicts with `docker-ce`. Existing Podman projects keep running on rootless Podman; use `podman` or `docker --context podman` for them.
- The `DOCKER_HOST` exports in `~/.bashrc` and `~/.config/environment.d/podman-docker.conf` are replaced by Docker CLI contexts. The Lab's scripts pin `DOCKER_HOST` to Docker CE's socket themselves, so k3d never lands on Podman.
- Docker 28+ sets the FORWARD chain's policy to DROP, which can break libvirt and Podman bridge forwarding. If it does, allow that traffic with a `DOCKER-USER` rule.
- A shell started before the switch still points `docker` at Podman until you log in again; Podman's "image not known" error is the tell. The Lab's scripts pin `DOCKER_HOST`, and `just doctor` warns when the environment still points at Podman.
- Docker CE's `data-root` lives at `/home/docker-data`, not `/var/lib/docker`, because the Host's root volume is small. The k3d Nodes keep k3s's image store and kubelet directories there, so kubelet's disk-pressure evictions track `/home`'s free space. With the root volume nearly full, the Server was tainted `disk-pressure` right after the cluster was created. `just host-setup` configures the new location, including an SELinux file-context equivalence with `/var/lib/docker`, and `just doctor` checks free space there.
- Installing Docker CE revived old state in `/var/lib/docker`, including an unrelated kind cluster that restarts automatically. Never prune Docker images blindly on this Host: `docker image prune -a` would delete images loaded into kind that no Docker container uses.

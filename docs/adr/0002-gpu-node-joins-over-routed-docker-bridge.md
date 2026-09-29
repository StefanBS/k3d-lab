# The GPU Node joins through a routed Docker bridge

The GPU Node is a wired, Fedora-based machine (it runs Nobara) on the LAN that joins the Lab occasionally as an Agent. It has to reach the k3d Nodes, which live on a Docker bridge network inside a Host that connects only over WiFi. macvlan/ipvlan would give the k3d Nodes real LAN IPs, but WiFi generally won't carry the extra MAC addresses. A Tailscale/WireGuard overlay would work, but it adds a dependency and an auth key for something used now and then. Instead we route:

- The Lab uses a fixed Docker subnet, `172.28.0.0/16`, created with `com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected`, because Docker 28+ otherwise blocks routed access to containers. Docker 29 puts the bridge in firewalld's `docker` zone, and its `docker-forwarding` policy already accepts traffic from the LAN, so no `DOCKER-USER` rule or other firewalld change is needed.
- The GPU Node gets a static route to that subnet via the Host's LAN IP, and joins the Server directly at its bridge IP.
- Cilium runs in VXLAN tunnel mode.

The prototype on branch `prototype/gpu-node-join` proved this path works end to end; see `prototype/gpu-node-join/FINDINGS.md` on that branch.

## Consequences

- The Host needs a DHCP reservation. If its LAN IP changes, the GPU Node's route breaks. `HOST_LAN_IP` in `.env` is the source of truth; `just doctor` and `just verify` warn when it no longer matches the Host's actual address, and re-running `gpu-join` rewrites the route.
- The route is a NetworkManager route on the GPU Node's wired connection, so it survives reboots while the node is joined. `gpu-join` adds it and `gpu-leave` removes it.
- `gpu-join` and `gpu-leave` reach the GPU Node over SSH as a dedicated `k3dlab` user with its own key and `NOPASSWD: ALL` sudo. This is deliberate: `gpu-join` runs k3s's installer as root, so limiting sudo to specific commands wouldn't reduce what the user can do. The SSH key is the security boundary.
- The Lab must never depend on the GPU Node. `just gpu-join` and `just gpu-leave` add and remove it, and the GPU Node is tainted so that only GPU Workloads are scheduled there.
- The GPU Node's k3s version must match the Server's exactly, so `gpu-join` reads it from the running cluster.
- Cilium must be installed with `cgroup.autoMount.enabled=false` and `cgroup.hostRoot=/sys/fs/cgroup`. With the defaults, inside a k3d Node, Cilium attaches its service load-balancing hooks to its own container's cgroup, and every ClusterIP times out. A later `helm upgrade` doesn't fix it, because the pinned BPF links stay attached to the old cgroup. Changing this setting means recreating the Lab.
- The GPU Node shares a large disk with other uses, so k3s's percentage-based eviction thresholds (5% free) would evict pods even with plenty of room left. `gpu-join` writes absolute thresholds into that node's own k3s config (default 20 GiB hard and 5 GiB minimum reclaim, overridable). The k3d Nodes keep k3s's defaults.
- `k3s-agent-uninstall.sh` doesn't remove Cilium's state from the GPU Node. That state includes network links, BPF pins in `/sys/fs/bpf` (including service load-balancing hooks still attached to the node's root cgroup), a cgroup2 mount, `CILIUM` iptables rules, and the CNI files. `gpu-leave` has to clean up all of it.
- `gpu-join` detects the GPU Node's SELinux mode and GPU device permissions rather than assuming them. On this GPU Node, SELinux is disabled and `/dev/kfd` is world-accessible, so neither `k3s-selinux` nor `supplementalGroups` is needed.

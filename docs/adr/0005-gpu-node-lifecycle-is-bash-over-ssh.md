# The GPU Node's lifecycle is one bash file run over SSH, not Ansible

Joining and leaving the GPU Node (ADR 0002) means running commands on another machine as root. The prototype did that with commands quoted inside the Host's scripts, `ssh … "sudo bash -c '…'"`, which shellcheck can't read and nothing can run on its own. So the GPU Node's half is now a file of its own, `scripts/gpu-node.sh`, with one subcommand per transition: `setup`, `join`, `leave`, `purge` and `status`. The Host sends it over SSH stdin, as `ssh $GPU_NODE_SSH sudo env KEY=value … bash -s -- <subcommand>`, and `scripts/gpu.sh` keeps the half that needs the Lab.

Ansible was the other candidate, since running idempotent steps over SSH is what it's for. But the work on the GPU Node is mostly imperative cleanup that no Ansible module covers: deleting Cilium's links, unpinning its BPF programs, unmounting its cgroup2 mount, and filtering `CILIUM` rules out of `iptables-save`. The install itself is k3s's `curl | sh`. All of that would be `command` and `shell` tasks, so Ansible would add Python, a second language and slower runs without making anything idempotent that isn't already.

## Considered Options

- **Ansible**, with an inventory built from `.env`: see above. It would pay off on the Host's own setup, if anywhere, and that's a separate decision.
- **Commands quoted inside the Host's scripts**, as in the prototype: no new file, but quoting through two shells, and no way to lint or run the GPU Node's half alone.
- **Copying the file to the GPU Node** and running it there: a copy that can drift from the repo, for no gain over stdin.

## Consequences

- `gpu-node.sh` never sources `lib.sh`, which needs mise and Docker. The Host passes every value `lib.sh` and `.env` define, such as the Lab's subnet, `HOST_LAN_IP`, the Server's URL and the k3s version, as environment variables, and the join token on stdin. `gpu-node.sh` knows only the GPU Node: its paths, what to clean up, and how to detect SELinux and GPU device permissions.
- `join` decides its own path. An install whose saved token carries the current Lab's CA hash (`K10<hash>::`) only needs its agent started; a Stale install is cleaned up and reinstalled; otherwise k3s is installed.
- `status` prints the GPU Node's state and one line per leftover. It's the definition of "clean" that `join`, `leave`, `just down`, `just gpu-status` and the acceptance runs share. `just verify` never calls it: it reads only the cluster, so the Lab doesn't depend on the GPU Node.
- `setup` creates the `k3dlab` user. It runs once, by hand, with sudo as you on the GPU Node, before that user exists; `just gpu-wizard` prints the commands and then tests the login.
- There's one GPU Node, so `gpu-node.sh` is tested by shellcheck through `just lint` and by runs on the real machine, not against a stand-in.

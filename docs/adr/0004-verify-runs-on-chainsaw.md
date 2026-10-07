# `just verify` runs on Chainsaw

`just verify` was a bash script that had grown its own test runner: named checks, retries, waiting for pods, and matching status with jsonpath and awk. Almost every Platform component still to come adds checks of the form "resource X reaches state Y" or "a request through Y succeeds". So the checks are now Chainsaw tests, one folder per check under `verify/`, and `scripts/verify.sh` is a thin wrapper around `chainsaw test`.

It was a close call. Chainsaw can't run a step once per node, so every check that runs on every Ready node is still a bash loop (`verify/lib/on-ready-nodes.sh`) inside a `script` step. Chainsaw also has no WARN outcome and can't skip a test based on the Lab's state. Those jobs stay in the wrapper.

## Considered Options

- **Plain bash, with the helpers moved into a library**: no new tool, but every new check would keep paying for hand-written retries and status parsing.
- **bats-core**: a proper runner for tests written in bash, but no declarative assertions on resources, and no waiting built in.
- **The cilium CLI** (`cilium status`, `cilium connectivity test`): thorough for Cilium, but it only covers Cilium, and the connectivity test takes minutes.

## Consequences

- **The wrapper's jobs:**
  - It stops early when the Lab doesn't answer, so there's one clear failure instead of one per check.
  - It decides whether the GPU checks run, filtering them by label with `--selector`:
    - GPU Node Left: GPU checks left out, silently.
    - Joined and Ready: GPU checks run.
    - Joined but NotReady (powered off): GPU checks left out, with a WARN (ADR 0002).
  - It runs only the checks named first, as in `just verify cilium-healthy`, and fails on a name with no folder in `verify/`. Chainsaw itself passes when a filter matches nothing (its regex is matched against `chainsaw/<check>`), so a typo would otherwise look like success.
  - It passes any other arguments on to Chainsaw, after the check names.
- **Isolation:** each check runs in its own throwaway namespace and deploys its own probes there, so the checks can run concurrently, and `verify` leaves nothing in the Lab outside Git.
  - The exception is a check of a Workload's network policies, such as `network-policy-enforced` and `gpu-node-dns-proxy`: a policy applies only in its own namespace, so the probe has to run there. It's a single pod with a name of the check's own, which the check deletes afterwards, and which no Workload's Services or own allow rules select; only the baseline's same-namespace allow does (ADR 0008). `network-policy-enforced` finds the Workloads' namespaces by their label at run time, so its script applies and deletes the probes itself, since Chainsaw only applies into namespaces it's told.
  - `workload-network-baseline` creates namespaces of its own, labelled as a Workload's, so the Platform's policies apply to them, and deletes them afterwards. They're also labelled `k3d-lab/verify`, so `network-policy-enforced` doesn't take them for Workloads'.
- **Output:** it follows Chainsaw's own format, with a PASS or FAIL for each check, rather than the one-line-per-check format that doctor and lint use.
- **Traps when writing a check:**
  - A bare `assert` passes when *at least one* resource matches. To say "every X is Y", use `error` on the opposite condition, and guard separately against an empty list.
  - `script` steps run with a temporary kubeconfig whose only context is `chainsaw`, so they call plain `kubectl`, not `lib.sh`'s `kc`.

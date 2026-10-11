# Testing a change on the Lab

How to prove a branch works, and how to leave the Host afterwards. Every command here was run as written on 2026-10-10.

## The test is a debugging run

- **`just up --debug` on a fresh Lab is the test of a change.** It builds everything in Git, the Demos included. A bare `just up` only builds, without the Demos: it runs no check. Push the branch first, since ArgoCD builds from what's pushed. The build took 8 to 10 minutes.
- **`just track --debug` tests a change on a running Lab,** without the rebuild. It tests the Lab as it is: on a Lab without its Demos, `verify` skips their checks and says so. `just demos on` adds them first.
- **Run either in the background and read its log as it goes**, such as `just up --debug >"$log" 2>&1 &`. Edit no script while it runs (`docs/agents/shell.md`).

## Rebuilding a Lab that's in use

A rebuild needs no asking first. Leave the Host as it was:

1. Note whether the GPU Node is Joined: `kubectl --context k3d-lab get nodes` lists it beside the two k3d Nodes.
2. While it's Joined, check ComfyUI is idle: `curl -s https://comfyui.lab.localhost/queue` prints `{"queue_running": [], "queue_pending": []}`. With a job running or pending, wait for it, or ask.
3. `just down`, which takes a Joined GPU Node back, then `just up --debug`.
4. `just gpu join` if the GPU Node was Joined.
5. `just track main` when the branch changes no manifest. The Lab otherwise tracks a branch that the merge deletes.

## Making a run fail on purpose

For a change to what `up` or `track` print when k3s restarts or a wait times out. `track` reaches both in minutes, without a rebuild.

- **A run that succeeds after a k3s restart:** start `just track <another branch>`, so the root Application is behind for some seconds, and run `docker restart -t 5 k3d-lab-server-0` once it logs "Waiting for the root Application". That wait outlasts an API that doesn't answer.
- **A run that times out:** as above, then `docker stop -t 1 k3d-lab-server-0` once it logs "Waiting for the ApplicationSets". It fails after 5 minutes. `docker start k3d-lab-server-0` afterwards; the Server keeps its address.
- **Whether a run recorded or ran checks:** sample `pgrep -x -l 'below|chainsaw'` while it runs. A regular run shows neither.
- **Wait for the Lab between runs:** `until kubectl --context k3d-lab get --raw /readyz --request-timeout=5s >/dev/null 2>&1; do sleep 2; done`.

## Cutting the Lab off from GitHub on purpose

For a change to how ArgoCD rides out a Host whose uplink drops (#159). It takes a minute, on a running Lab:

```bash
for n in k3d-lab-server-0 k3d-lab-agent-0; do docker exec "$n" iptables -I FORWARD -d 140.82.112.0/20 -j DROP; done
kubectl --context k3d-lab -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 20
for n in k3d-lab-server-0 k3d-lab-agent-0; do docker exec "$n" iptables -D FORWARD -d 140.82.112.0/20 -j DROP; done
sleep 15
kubectl --context k3d-lab -n argocd get application root -o jsonpath='{.status.conditions[*].message}{"\n"}'
```

- **It prints an empty line after a cut of 20s or 30s.** After 50s it prints `failed to list refs: ... context deadline exceeded (Client.Timeout exceeded while awaiting headers)`: the repo server gives each request 15s and tries three times (`platform/argocd/values.yaml`). With one attempt, 20s was enough to fail.
- **Cut both k3d Nodes.** The repo server's pod runs on either, and a cut on the other Node alone passes without testing anything.
- **Check the cut reached GitHub's address:** `getent hosts github.com` printed one inside `140.82.112.0/20` on 2026-10-11. GitHub has other ranges.
- **One failed fetch stays on the Application for minutes.** It cleared 3m47s later, at the next refresh, which is longer than a check waits. Clear it sooner with the same `annotate`, with `refresh=normal`, and let that refresh finish before the next cut: a cut of 50s started right behind one printed an empty line.

## A check that fails on a fetch from GitHub

Look at the Host's uplink before the Lab. On 2026-10-10 three such failures in 20 minutes each fell inside a Wi-Fi drop of 4 to 30 seconds, with no pressure on the repo server's pod or on CoreDNS:

```bash
journalctl -u wpa_supplicant --since '1 hour ago' | grep -E 'CTRL-EVENT-(DIS)?CONNECTED'
```

A `CTRL-EVENT-DISCONNECTED` at the time of the failure is the cause. Run the check again once the uplink holds.

## Making lint fail on purpose

For a new lint rule: prove it fails on what it forbids.

- **Commit first.** `git restore <file>` discards every uncommitted edit to the file, not only the one made to break it.
- **Break one thing, run lint, restore:** `sed -i 's/^role: demo/role: other/' workloads/rollouts-demo/component.yaml; just lint; git restore workloads/rollouts-demo/component.yaml`. It prints `FAIL  workloads/rollouts-demo/component.yaml: 'role' can only be 'demo'` and fails.

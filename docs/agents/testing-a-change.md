# Testing a change on the Lab

How to prove a branch works, and how to leave the Host afterwards. Every command here was run as written on 2026-10-10.

## The test is a debugging run

- **`just up --debug` on a fresh Lab is the test of a change.** A bare `just up` only builds: it runs no check. Push the branch first, since ArgoCD builds from what's pushed. The build took 8 to 10 minutes.
- **`just track --debug` tests a change on a running Lab,** without the rebuild.
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

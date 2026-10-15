# Coding standards

Judgement calls for review. What a tool can check lives in `just lint` instead.

## Scripts

- **A script's folder says how it runs.** `scripts/*.sh` are run. `scripts/lib/` holds the modules they source after `scripts/lib.sh`: a module sets no shell options and runs nothing when sourced. `scripts/remote/` is sent to another machine over SSH, so it never sources `lib.sh` (ADR 0005). `just lint` checks each.
- **Logic that needs no Lab is tested without one.** It lives in a module in `scripts/lib/`, with bats tests in `scripts/tests/`, as `scripts/lib/gpu-node-status.sh` does. The script that uses it only fetches state and acts on the answer. `scripts/remote/gpu-node.sh` reaches the GPU Node as one file, so it can't source another: its own functions are tested instead, by sourcing it in a bash of its own, where it runs nothing, with stubs for the commands it calls (`scripts/tests/gpu-node.bats`). An issue's "Test seams: None" means the change needs no new seam; it doesn't waive this.
- **A wait treats a failed request as "not yet".** A Lab under a sync's load can restart k3s, so one failed `kubectl` call should neither end a wait nor pass it. Check each wait in both directions: an error that prints nothing must not read as done.
- **A wait shows progress, and gives up.** It logs what it's still waiting for whenever that changes, and fails after a deadline with what was still pending.
- **A check cleans up what a crashed run left behind.** Chainsaw's cleanup only runs if Chainsaw does, so anything a check creates outside its own namespace, in YAML or a script, it first deletes. It waits for that to go when the next run reuses the name. Chainsaw's own namespaces, `chainsaw-*`, `verify.sh` deletes before the run.
- **A recipe does what its name says.** Another way to change the running Lab gets its own recipe and script, as `just demos` did, even when it shares a recipe's mechanics: `just track` only tracks a branch.
- **Recipes stay thin.** A recipe calls one script; the logic lives in `scripts/` (the `Justfile`'s header).
- **Comments say why.** Plain full sentences, about what the code can't say itself.

## Docs

- **A how-to's commands were run as written,** and its numbers come from that run. A PR that couldn't run them says so, and doesn't close the issue.

## Language

- Name things with `CONTEXT.md`'s terms, and none of its _Avoid_ words, in code, comments, output and docs.

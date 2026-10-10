# AGENTS.md

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on `StefanBS/k3d-lab`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Coding standards

Reviewing a diff: read `CODING_STANDARDS.md` first.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Measuring the Lab

Measuring the Lab's datastore writes, memory, swap or pressure, reproducing a datastore stall, freezing its API server, changing the running Server for an experiment, or querying its Prometheus: read `docs/agents/measuring-the-lab.md` first.

### ROCm libraries in ComfyUI

Measuring ComfyUI's idle CPU, testing another build of a ROCm library in its pod, or changing the `rocm/pytorch` tag: read `docs/agents/rocm-library-ab.md` first.

### Testing a change on the Lab

Proving a branch works, rebuilding the Lab, or making `up` or `track` fail on purpose: read `docs/agents/testing-a-change.md` first.

### Shell gotchas

Writing an awk, yq or jq program, parsing kubectl JSON, reading tab-separated fields, matching a process with `pgrep`, or editing a script that's running: read `docs/agents/shell.md` first.

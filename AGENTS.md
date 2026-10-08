# AGENTS.md

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues on `StefanBS/k3d-lab`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Shell gotchas

Writing yq beyond a path lookup, parsing kubectl JSON, or reading tab-separated fields: read `docs/agents/shell.md` first.

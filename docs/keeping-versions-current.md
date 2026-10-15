# Keeping versions current

Renovate (`renovate.json5`) opens PRs for every pinned version that has a newer release: the charts in `component.yaml`, the k3s image, image tags, the tools in `mise.toml`, CI's actions and mise, GitHub release assets, and the Secret Store's image in `scripts/lib/secret-store.sh`. It groups related updates into one PR, such as Observability or GPU, and lists everything it tracks in its Dependency Dashboard issue. It never merges: every PR runs `just lint`, and waits for you.

A pin in a file Renovate can't read by itself, such as a script, gets a comment on the line above, like the Secret Store's image in `scripts/lib/secret-store.sh`. It works in any `.sh` or YAML file and the Justfile:

```bash
# renovate: datasource=docker depName=<image>
SOME_IMAGE=<image>:<version>
```

Groups name their dependencies in `renovate.json5`, so a new component joins one, such as Observability, with a line there too; otherwise it gets PRs of its own.

Renovate is a GitHub app, so enabling it is a step you do yourself, once: install the [Renovate app](https://github.com/apps/renovate) on your account with access to this repo only. With `renovate.json5` already on `main`, it skips its onboarding PR and opens the Dependency Dashboard and the update PRs straight away.

Some updates need more than a merge: the Argo Rollouts Gateway API plugin needs its new `sha256`, and the Secret Store reaches the new image only when you re-run `just host setup`. Their PRs say so.

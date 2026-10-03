# The Secret Store's recipes, as `just secret-store <recipe>`. Recipes stay thin; the
# logic lives in scripts/. They run in just/, so they name scripts from the repo's root.

# Run the bao CLI against the Secret Store as its root, e.g. `just secret-store bao kv put -mount=lab workloads/<workload>/<key> <field>=<value>`
[positional-arguments]
bao *args:
    @{{ justfile_directory() }}/scripts/bao.sh "$@"

# Archive the Secret Store's data, unseal key and root token into a directory or to an archive path
backup path:
    @{{ justfile_directory() }}/scripts/secret-store-backup.sh {{ quote(path) }}

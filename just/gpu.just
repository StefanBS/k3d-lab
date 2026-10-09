# The GPU Node's recipes, as `just gpu <recipe>`. Recipes stay thin; the logic lives in
# scripts/. They run in just/, so they name scripts from the repo's root.

# `just <module>` runs the module's first recipe, so this one only lists the others.
_default:
    @just --justfile {{ justfile() }} --list {{ module_path() }}

# Walk through the GPU Node step only you can do: creating the user the Host logs in as
wizard:
    @{{ justfile_directory() }}/scripts/gpu-wizard.sh

# Lend the GPU Node to the Lab; eviction=<size> sets its free-disk threshold (20Gi)
join *args:
    @{{ justfile_directory() }}/scripts/gpu.sh join {{ args }}

# Take the GPU Node back, keeping its install; `just gpu leave purge` removes that too
leave *args:
    @{{ justfile_directory() }}/scripts/gpu.sh leave {{ args }}

# Show the GPU Node's state, in the Lab and on the machine
status:
    @{{ justfile_directory() }}/scripts/gpu.sh status

# Run a command on the GPU Node, or open a shell there; quote one with a redirect, e.g. `just gpu ssh 'cat > <path>' < <file>`
[positional-arguments]
ssh *args:
    @{{ justfile_directory() }}/scripts/gpu.sh ssh "$@"

# The Host's recipes, as `just host <recipe>`. Recipes stay thin; the logic lives in
# scripts/. They run in just/, so they name scripts from the repo's root.

# List the recipes; `just <module>` runs a module's first recipe
_default:
    @just --justfile {{ justfile() }} --list {{ module_path() }}

# Prepare the Host once; safe to re-run. Says when to run the root steps yourself
setup:
    @{{ justfile_directory() }}/scripts/host-setup.sh

# Walk through the Host steps only you can do, such as the router's DHCP reservation
wizard:
    @{{ justfile_directory() }}/scripts/host-wizard.sh

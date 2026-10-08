# ComfyUI's recipes, as `just comfyui <recipe>`. Recipes stay thin; the logic lives in
# scripts/. They run in just/, so they name scripts from the repo's root.

# List the recipes; `just <module>` runs a module's first recipe
_default:
    @just --justfile {{ justfile() }} --list {{ module_path() }}

# Regenerate config/requirements.txt for the ComfyUI commit in config/setup.sh, in its image on the Joined GPU Node
lock:
    @{{ justfile_directory() }}/scripts/comfyui-lock.sh

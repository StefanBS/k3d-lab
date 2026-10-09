# The Lab's interface. Recipes stay thin; the logic lives in scripts/.
# The recipes for one part of the Lab are a module in just/, run as `just <module> <recipe>`.

set dotenv-load

# Every script pins DOCKER_HOST to Docker CE (scripts/lib.sh, ADR 0001), so no recipe
# lands on another engine.

# The Host: preparing it once
mod host 'just/host.just'

# The Secret Store on the Host (ADR 0003)
mod secret-store 'just/secret-store.just'

# The GPU Node: lending it to the Lab and taking it back (ADRs 0002 and 0005)
mod gpu 'just/gpu.just'

# ComfyUI: regenerating its lock (ADR 0007)
mod comfyui 'just/comfyui.just'

# List the recipes
default:
    @just --list --list-submodules

# Check that the Host has what the Lab needs
doctor:
    @scripts/doctor.sh

# Build the Lab from the pushed branch checked out here, then verify it; REVISION=<branch> picks another
up *args:
    @scripts/up.sh {{ args }}

# Point the running Lab at the pushed branch checked out here, or at <branch>, then verify it
track *branch:
    @scripts/track.sh {{ branch }}

# Stop ArgoCD syncing one Workload or Platform component, so changes made by hand to it stay
pause name:
    @scripts/pause.sh pause {{ name }}

# Let ArgoCD sync a paused Workload or Platform component again, putting Git back
resume name:
    @scripts/pause.sh resume {{ name }}

# Destroy the Lab, taking a Joined GPU Node back first (the Host's Secret Store, Lab CA and Docker CE are kept)
down:
    @scripts/down.sh

# Print the Lab's UIs and how to log in to them
creds:
    @scripts/creds.sh

# Check how the running Lab behaves; `just verify <check>...` runs only those checks
verify *args:
    @scripts/verify.sh {{ args }}

# Static checks; needs no Lab
lint:
    @scripts/lint.sh

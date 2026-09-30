# The Lab's interface. Recipes stay thin; the logic lives in scripts/.

set dotenv-load

# Every script pins DOCKER_HOST to Docker CE (scripts/lib.sh, ADR 0001), so no recipe
# lands on Podman. It isn't exported here, so `doctor` can still see the caller's value.

# List the recipes
default:
    @just --list

# Check that the Host has what the Lab needs
doctor:
    @scripts/doctor.sh

# Build the Lab, then verify it; REVISION=<branch> builds it from a branch other than main
up *args:
    @scripts/up.sh {{ args }}

# Destroy the Lab (the Host's Secret Store and Lab CA are kept)
down:
    @scripts/down.sh

# Check how the running Lab behaves
verify:
    @scripts/verify.sh

# Static checks; needs no Lab
lint:
    @scripts/lint.sh

# The Lab's interface. Recipes stay thin; the logic lives in scripts/.

set dotenv-load

# List the recipes
default:
    @just --list

# Check that the Host has what the Lab needs
doctor:
    @scripts/doctor.sh

# Build the Lab, then verify it
up:
    @scripts/up.sh

# Destroy the Lab (the Host's Secret Store and Lab CA are kept)
down:
    @scripts/down.sh

# Check how the running Lab behaves
verify:
    @scripts/verify.sh

# Static checks; needs no Lab
lint:
    @scripts/lint.sh

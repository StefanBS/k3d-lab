# The Lab's interface. Recipes stay thin; the logic lives in scripts/.

set dotenv-load

# Every script pins DOCKER_HOST to Docker CE (scripts/lib.sh, ADR 0001), so no recipe
# lands on another engine.

# List the recipes
default:
    @just --list

# Check that the Host has what the Lab needs
doctor:
    @scripts/doctor.sh

# Prepare the Host once; safe to re-run. Says when to run the root steps yourself
host-setup:
    @scripts/host-setup.sh

# Walk through the Host steps only you can do, such as the router's DHCP reservation
host-wizard:
    @scripts/host-wizard.sh

# Build the Lab from the pushed branch checked out here, then verify it; REVISION=<branch> picks another
up *args:
    @scripts/up.sh {{ args }}

# Destroy the Lab (the Host's Secret Store, Lab CA and Docker CE are kept)
down:
    @scripts/down.sh

# Print the Lab's UIs and how to log in to them
creds:
    @scripts/creds.sh

# Run the bao CLI against the Secret Store as its root, e.g. `just bao kv put -mount=lab workloads/<workload>/<key> <field>=<value>`
[positional-arguments]
bao *args:
    @scripts/bao.sh "$@"

# Archive the Secret Store's data, unseal key and root token into a directory or to an archive path
vault-backup path:
    @scripts/vault-backup.sh {{ quote(path) }}

# Check how the running Lab behaves; `just verify <check>...` runs only those checks
verify *args:
    @scripts/verify.sh {{ args }}

# Static checks; needs no Lab
lint:
    @scripts/lint.sh

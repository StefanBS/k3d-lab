#!/usr/bin/env bash
# Adds the Demos to the running Lab, or removes them, without rebuilding it, and stops
# once their Applications are Settled, or gone with their namespaces.
# Usage: demos.sh on|off. `just up --demos` builds a Lab with them from the start.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

(($# == 1)) && [[ $1 == on || $1 == off ]] || die "usage: just demos on|off"
if [[ $1 == on ]]; then demos=true; else demos=false; fi

need_root_application
# The Demos, as this checkout has them, like the checks that verify runs.
mapfile -t demo_components < <(demo_dirs)
((${#demo_components[@]})) || die "no Workload in workloads/ is a Demo (role: demo in its component.yaml)"
need_none_paused "${demo_components[@]##*/}"

log "Turning the Lab's Demos $1: ${demo_components[*]##*/}"
root_application_set_demos "$demos"
settle_demos "$1"

# What each run waits for after it changes the Lab, and in what order: one function per
# change, which owns its deadlines. The run scripts say only what they changed. Sourced by
# lib.sh, and on its own by scripts/tests/, so it sets no shell options and runs nothing
# when sourced.
# shellcheck shell=bash

# settle_new_lab <commit>: once up.sh has applied the root Application, at that commit.
# The root Application can be Healthy before it has even created the ApplicationSets, so
# they're waited for by name, as the gitops chart renders them. Once each says
# ResourcesUpToDate, every Application exists to be waited for: the wait for them to be
# Settled counts only those that ArgoCD lists. The root Application creates each
# ApplicationSet once the Waves before it are Healthy (ADR 0014), so the last is created
# near the end of the Platform's install: each wait is as long as a root sync.
settle_new_lab() {
  local commit=$1 appsets
  mapfile -t appsets < <(gitops_applicationsets)
  # Without names, the wait would count whichever ApplicationSets are listed.
  ((${#appsets[@]})) || die "the gitops chart renders no ApplicationSets"
  need_none_paused
  log "Waiting for ArgoCD to sync the Lab at ${commit:0:7}"
  wait_applicationsets 900 "${appsets[@]}"
  wait_settled 900 --at "$commit"
}
# The ApplicationSets that the gitops chart renders, one name per line.
gitops_applicationsets() {
  helm template gitops "$LAB_ROOT/gitops" --show-only templates/applicationsets.yaml |
    yq -N 'select(.kind == "ApplicationSet") | .metadata.name'
}

# settle_demos on|off: once the root Application has the Demos, or doesn't. Run again on
# a Lab that already has them, or doesn't, it finds nothing to wait for.
settle_demos() {
  local dirs names dir namespaces=() commit
  [[ $1 == on || $1 == off ]] || die "settle_demos takes on or off, not '$1'"
  mapfile -t dirs < <(demo_dirs)
  # Without names, the waits would count every Application.
  ((${#dirs[@]})) || die "no Workload in workloads/ is a Demo (role: demo in its component.yaml)"
  names=("${dirs[@]##*/}")
  need_none_paused "${names[@]}"
  if [[ $1 == on ]]; then
    commit=$(tracked_commit)
    log "Waiting for the Demos to sync ${commit:0:7}: ${names[*]}"
    wait_settled 600 --at "$commit" "${names[@]}"
    return
  fi
  log "Waiting for ArgoCD to delete the Demos: ${names[*]}"
  wait_settled 600 --gone "${names[@]}"
  # ArgoCD deletes what a Demo's Application installed, but not the namespace it created
  # for it, which still carries the Workloads' label: network-policy-enforced would fail
  # on a Workload namespace that no Application has.
  for dir in "${dirs[@]}"; do namespaces+=("$(component_namespace "$dir")"); done
  log "Deleting the Demos' namespaces: ${namespaces[*]}"
  wait_namespaces_deleted 300 "${namespaces[@]}"
}

# settle_join: once gpu.sh has the GPU Node Ready. The Platform's networking, logs and
# metrics then run there too. GPU Workloads are DaemonSets as well (ADR 0006), but they
# start in their own time, such as after pulling a large image, so a join waits for
# neither their pods nor their Applications.
settle_join() {
  local platform names commit
  platform=$(applications_in_group platform) || die "can't read the Lab's Applications"
  mapfile -t names <<<"$platform"
  need_none_paused "${names[@]}"
  commit=$(tracked_commit)
  log "Waiting for the Platform's DaemonSets to run on the GPU Node"
  # The DaemonSet controller counts the new node a moment after it's Ready: until then,
  # each DaemonSet says it's Ready on every node it knows.
  sleep 2
  wait_daemonsets_ready 180 "${names[@]}"
  # ArgoCD sees a DaemonSet Healthy again a few seconds after its pods are.
  log "Waiting for the Platform's Applications to be Settled at ${commit:0:7}"
  wait_settled 180 --at "$commit" --group platform
}

# settle_resume <Application>: once 'just resume' has lifted its pause, has ArgoCD compare
# it with Git now, rather than at its next poll, then waits for it to be Settled.
settle_resume() {
  local app=$1 commit
  need_none_paused "$app"
  commit=$(tracked_commit)
  refresh_applications "$app"
  log "Waiting for ArgoCD to put $app back as Git has it at ${commit:0:7}"
  wait_settled 600 --at "$commit" "$app"
}

# settle_start: once start.sh has started the k3d Nodes again. Their pods start again
# with them, so each Application is Healthy again a while after the nodes are Ready. Each
# Application's status still says what ArgoCD saw before the Lab stopped, so they're
# all refreshed first, and waited for until ArgoCD has compared each again. The GPU Node
# isn't waited for: it's Left after its own reboot, or off (ADR 0002). Nor is a paused
# Application, which may stay OutOfSync with what was changed by hand.
settle_start() {
  local listed paused names
  log "Waiting for the k3d Nodes to be Ready"
  wait_nodes_ready 300 -l "!$GPU_NODE_LABEL_KEY"
  listed=$(kc -n argocd get applications -o json | jq -r '.items[].metadata.name') ||
    die "can't read the Lab's Applications"
  paused=$(paused_applications) || die "can't read the Lab's AppProjects"
  mapfile -t names < <(grep -vxF -f <(printf '%s\n' "$paused") <<<"$listed")
  ((${#names[@]})) || die "the Lab has no Applications that aren't paused"
  refresh_applications || die "can't refresh the Lab's Applications"
  log "Waiting for the Applications to be Settled${paused:+, but those paused: $(paste -sd' ' <<<"$paused")}"
  wait_settled 600 "${names[@]}"
}

# need_none_paused [<Application>...]: fails, naming them, if any of those Applications,
# or any at all without names, is paused: ArgoCD never syncs it, so a wait for it would
# only time out. Each settle_* checks first; track and demos also check before they change
# the Lab, so a paused Application leaves it as it was.
need_none_paused() {
  local paused
  paused=$(paused_applications) || die "can't read the Lab's AppProjects"
  if (($#)); then paused=$(grep -xF -f <(printf '%s\n' "$@") <<<"$paused" || true); fi
  paused=$(paste -sd' ' <<<"$paused")
  [[ -z $paused ]] || die "paused, so they'd never be Settled: $paused; 'just resume <name>' each first"
}

# settle_track <commit>: once the root Application tracks a new revision, at that commit.
# Each step waits for what the one before it changed, and the deadlines are those of a
# root sync (ADR 0014), which takes until every Application is Healthy.
settle_track() {
  local commit=$1
  need_none_paused
  log "Waiting for the root Application to sync ${commit:0:7}"
  wait_settled 900 --at "$commit" root
  # When only the Tracked revision's commit changed, the root's sync left the
  # ApplicationSets' spec as it was, so they'd wait for their next poll to read the
  # branch's components again, such as to generate a new component's Application.
  log "Waiting for the ApplicationSets to generate the Applications"
  refresh_applicationsets 300
  wait_applicationsets 300
  # Likewise, an Application whose spec the root's sync didn't change waits for a refresh.
  refresh_applications
  log "Waiting for every Application to sync ${commit:0:7}"
  wait_settled 900 --at "$commit"
}

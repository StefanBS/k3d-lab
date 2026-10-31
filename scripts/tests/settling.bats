#!/usr/bin/env bats
# What each run waits for after it changes the Lab (scripts/lib/settling.sh), without a
# Lab: kc answers for the Lab, LAB_REPO for pushed_commit, and the gitops chart for the
# ApplicationSets it renders.

setup() {
  for module in applications applicationsets pauses root-application components daemonsets namespaces nodes settling; do
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../lib/$module.sh"
  done
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  # LAB_REPO has main at main_commit.
  pushed_commit() {
    [[ $1 == main ]] || die "'$1' isn't a branch or tag of $LAB_REPO; push it first"
    echo "$main_commit"
  }
  kc_answers -n argocd get application/root -o 'jsonpath={.spec.source.targetRevision}' <<<main
  # No Application is paused.
  projects
}

main_commit=58f6f579d5fc05783fa2f7db28fd3c72d7e15ecb

# app <name> [<group>] [<synced at>]: an Application as ArgoCD lists it, Synced and Healthy
# at that commit of LAB_REPO, by default main_commit, in that group, by default platform.
app() {
  N=$1 G=${2:-platform} R=${3:-$main_commit} U=$LAB_REPO jq -n '{
    metadata: {name: env.N, labels: {"k3d-lab/group": env.G}},
    spec: {source: {repoURL: env.U, targetRevision: "main"}},
    status: {sync: {status: "Synced", revision: env.R, comparedTo: {source: {repoURL: env.U, targetRevision: "main"}}},
      health: {status: "Healthy"}}}'
}

# apps [<Application>...]: while the Lab lists those Applications, and those of a group
# for a selector on it.
apps() {
  local group
  printf '%s\n' "$@" | jq -s '{items: .}' | kc_answers -n argocd get applications -o json
  for group in platform workloads; do
    printf '%s\n' "$@" | jq -s --arg g "$group" '{items: map(select(.metadata.labels["k3d-lab/group"] == $g))}' |
      kc_answers -n argocd get applications -l "k3d-lab/group=$group" -o json
  done
}

# projects [<Application>...]: while those Applications are paused, each by 'just pause'.
projects() {
  jq -n '{items: [{spec: {syncWindows: $ARGS.positional | map({kind: "deny", applications: [.], description: "just pause"})}}]}' \
    --args "$@" | kc_answers -n argocd get appprojects -o json
}

# in_order <kc call>...: kc was called with each of those, in that order, among others.
in_order() {
  local want line=0 at
  for want; do
    at=$(grep -nxF -- "$want" "$KC_CALLS" | awk -F: -v after="$line" '$1 > after { print $1; exit }')
    [[ -n $at ]] || {
      echo "not called after line $line: $want"
      cat "$KC_CALLS"
      return 1
    }
    line=$at
  done
}

# Gives up at once: each wait's deadline passes on its first sleep.
give_up_at_once() { sleep() { SECONDS=$((SECONDS + 3600)); }; }

APPS="-n argocd get applications -o json"

@test "tracked_commit: the commit LAB_REPO has for the Tracked revision" {
  run tracked_commit
  [[ $status -eq 0 && $output == "$main_commit" ]]
}

@test "tracked_commit: fails when the root Application can't be read, or its revision isn't pushed" {
  rm "$KC_ANSWERS/$(kc_key -n argocd get application/root -o 'jsonpath={.spec.source.targetRevision}')"
  run tracked_commit
  [[ $status -eq 1 && $output == "error: can't read the Lab's root Application" ]]
  kc_answers -n argocd get application/root -o 'jsonpath={.spec.source.targetRevision}' <<<gone
  run tracked_commit
  [[ $status -eq 1 && $output == *"'gone' isn't a branch or tag"* ]]
}

REFRESH_COMFYUI="-n argocd annotate applications comfyui argocd.argoproj.io/refresh=hard --overwrite"

@test "resume: refreshes the Application, then waits for it Settled at the Tracked revision's commit" {
  kc_succeeds $REFRESH_COMFYUI
  apps "$(app comfyui workloads)" "$(app cilium platform 0123456789)"
  run settle_resume comfyui
  [[ $status -eq 0 && $output == *"${main_commit:0:7}"* ]]
  in_order "$REFRESH_COMFYUI" "$APPS"
}

@test "resume: synced at another commit at the deadline: fails naming it" {
  kc_succeeds $REFRESH_COMFYUI
  apps "$(app comfyui workloads 0123456789)"
  give_up_at_once
  run settle_resume comfyui
  [[ $status -eq 1 && $output == *"error: these Applications aren't Settled after 10 minutes:
comfyui: synced at 0123456" ]]
}

@test "resume: still paused: fails before waiting, naming it" {
  projects comfyui
  run settle_resume comfyui
  [[ $status -eq 1 && $output == *"error: paused, so they'd never be Settled: comfyui; 'just resume <name>' each first" ]]
  ! grep -qF -- "$APPS" "$KC_CALLS"
}

# appsets [<name>...]: while the Lab lists those ApplicationSets, each ResourcesUpToDate,
# with every refresh taken.
appsets() {
  jq -n '{items: $ARGS.positional | map({metadata: {name: .}, status: {conditions: [{type: "ResourcesUpToDate", status: "True"}]}})}' \
    --args "$@" | kc_answers -n argocd get applicationsets -o json
}

ASK_APPSETS="-n argocd annotate applicationsets --all argocd.argoproj.io/application-set-refresh=true --overwrite"
APPSETS="-n argocd get applicationsets -o json"
REFRESH_ALL="-n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite"

@test "track: the root Settled, then the ApplicationSets refreshed and up to date, then every Application refreshed and Settled, at the commit" {
  kc_succeeds $ASK_APPSETS
  kc_succeeds $REFRESH_ALL
  appsets platform workloads
  apps "$(app root)" "$(app cilium)" "$(app comfyui workloads)"
  run settle_track "$main_commit"
  [[ $status -eq 0 && $output == *"${main_commit:0:7}"* ]]
  in_order "$APPS" "$ASK_APPSETS" "$APPSETS" "$REFRESH_ALL" "$APPS"
}

@test "track: an Application synced at another commit at the deadline: fails naming it" {
  kc_succeeds $ASK_APPSETS
  kc_succeeds $REFRESH_ALL
  appsets platform
  apps "$(app root)" "$(app cilium platform 0123456789)"
  give_up_at_once
  run settle_track "$main_commit"
  [[ $status -eq 1 && $output == *"error: these Applications aren't Settled after 15 minutes:
cilium: synced at 0123456" ]]
}

@test "track: the root not Settled at the deadline: fails naming it, before any refresh" {
  apps "$(app root platform 0123456789)"
  give_up_at_once
  run settle_track "$main_commit"
  [[ $status -eq 1 && $output == *"root: synced at 0123456" ]]
  ! grep -qF -- "annotate" "$KC_CALLS"
}

@test "track: a refresh the controller never takes: fails naming its ApplicationSet" {
  kc_succeeds $ASK_APPSETS
  apps "$(app root)"
  jq -n '{items: [{metadata: {name: "platform", annotations: {"argocd.argoproj.io/application-set-refresh": "true"}}}]}' |
    kc_answers $APPSETS
  give_up_at_once
  run settle_track "$main_commit"
  [[ $status -eq 1 && $output == *"error: these ApplicationSets haven't refreshed after 5 minutes:
platform: refresh not taken yet" ]]
}

@test "track: any Application paused: fails before waiting, naming it" {
  projects comfyui
  run settle_track "$main_commit"
  [[ $status -eq 1 && $output == *"error: paused, so they'd never be Settled: comfyui; 'just resume <name>' each first" ]]
  ! grep -qF -- "$APPS" "$KC_CALLS"
}

@test "new Lab: the ApplicationSets the chart renders, by name, then every Application Settled at the commit" {
  gitops_applicationsets() { printf '%s\n' platform workloads; }
  appsets platform workloads
  apps "$(app root)" "$(app cilium)"
  run settle_new_lab "$main_commit"
  [[ $status -eq 0 && $output == *"${main_commit:0:7}"* ]]
  in_order "$APPSETS" "$APPS"
}

@test "new Lab: an ApplicationSet the chart renders not created at the deadline: fails naming it" {
  gitops_applicationsets() { printf '%s\n' platform workloads; }
  appsets platform
  give_up_at_once
  run settle_new_lab "$main_commit"
  [[ $status -eq 1 && $output == *"error: these ApplicationSets haven't generated their Applications after 15 minutes:
workloads: not created yet" ]]
}

@test "new Lab: an Application not Settled at the deadline: fails naming it" {
  gitops_applicationsets() { echo platform; }
  appsets platform
  apps "$(app root)" "$(app cilium platform 0123456789)"
  give_up_at_once
  run settle_new_lab "$main_commit"
  [[ $status -eq 1 && $output == *"error: these Applications aren't Settled after 15 minutes:
cilium: synced at 0123456" ]]
}

@test "new Lab: the chart renders no ApplicationSets: fails before waiting" {
  gitops_applicationsets() { :; }
  run settle_new_lab "$main_commit"
  [[ $status -eq 1 && $output == *"error: the gitops chart renders no ApplicationSets" ]]
  ! grep -qF -- "$APPSETS" "$KC_CALLS"
}

@test "new Lab: any Application paused: fails before waiting, naming it" {
  gitops_applicationsets() { echo platform; }
  projects cilium
  run settle_new_lab "$main_commit"
  [[ $status -eq 1 && $output == *"error: paused, so they'd never be Settled: cilium; 'just resume <name>' each first" ]]
  ! grep -qF -- "$APPSETS" "$KC_CALLS"
}

# The Demos rollouts-demo and podinfo, beside a Workload that isn't one.
demos() {
  local name
  for name in rollouts-demo podinfo comfyui; do mkdir -p "$LAB_ROOT/workloads/$name"; done
  printf 'role: demo\nnamespace: rollouts-demo\n' >"$LAB_ROOT/workloads/rollouts-demo/component.yaml"
  printf 'role: demo\nnamespace: podinfo-ns\n' >"$LAB_ROOT/workloads/podinfo/component.yaml"
  printf 'namespace: comfyui\n' >"$LAB_ROOT/workloads/comfyui/component.yaml"
}

# namespaces [<name>...]: while the Lab has those namespaces, beside kube-system.
namespaces() {
  jq -n '{items: ($ARGS.positional + ["kube-system"] | map({metadata: {name: .}}))}' --args "$@" |
    kc_answers get namespaces -o json
}

DELETE_NAMESPACES="delete namespace podinfo-ns rollouts-demo --ignore-not-found --wait=false"
NAMESPACES="get namespaces -o json"

@test "demos on: only the Demos' Applications, Settled at the Tracked revision's commit" {
  demos
  apps "$(app rollouts-demo workloads)" "$(app podinfo workloads)" "$(app comfyui workloads 0123456789)"
  run settle_demos on
  [[ $status -eq 0 && $output == *"${main_commit:0:7}"* ]]
}

@test "demos on: a Demo not generated at the deadline: fails naming it" {
  demos
  apps "$(app rollouts-demo workloads)"
  give_up_at_once
  run settle_demos on
  [[ $status -eq 1 && $output == *"error: these Applications aren't Settled after 10 minutes:
podinfo: not generated yet" ]]
}

@test "demos off: their Applications gone, then their namespaces deleted, then gone" {
  demos
  apps "$(app comfyui workloads)"
  kc_succeeds $DELETE_NAMESPACES
  namespaces comfyui
  run settle_demos off
  [[ $status -eq 0 ]]
  in_order "$APPS" "$DELETE_NAMESPACES" "$NAMESPACES"
}

@test "demos off: an Application still there at the deadline: fails naming it, deleting no namespace" {
  demos
  apps "$(app podinfo workloads)"
  give_up_at_once
  run settle_demos off
  [[ $status -eq 1 && $output == *"error: these Applications aren't gone after 10 minutes:
podinfo: still there" ]]
  ! grep -qF -- "delete" "$KC_CALLS"
}

@test "demos off: a namespace still there at the deadline: fails naming it" {
  demos
  apps
  kc_succeeds $DELETE_NAMESPACES
  namespaces podinfo-ns
  give_up_at_once
  run settle_demos off
  [[ $status -eq 1 && $output == *"error: these namespaces aren't gone after 5 minutes:
podinfo-ns: still there" ]]
}

@test "demos off: a failed request to delete them is pending, not passed" {
  demos
  apps
  namespaces
  give_up_at_once
  run settle_demos off
  [[ $status -eq 1 && $output == *"error: these namespaces aren't gone after 5 minutes:
the Lab's API isn't answering" ]]
}

@test "demos: a Demo paused: fails before waiting, naming only it" {
  demos
  projects podinfo cilium
  run settle_demos on
  [[ $status -eq 1 && $output == *"error: paused, so they'd never be Settled: podinfo; 'just resume <name>' each first" ]]
  ! grep -qF -- "$APPS" "$KC_CALLS"
}

# daemonset <namespace>/<name> <Application> <desired> <ready> <up to date>: a DaemonSet
# as the Lab lists it, which that Application installed.
daemonset() {
  N=${1#*/} NS=${1%/*} A=$2 jq -n --argjson d "$3" --argjson r "$4" --argjson u "$5" '{
    metadata: {name: env.N, namespace: env.NS,
      annotations: {"argocd.argoproj.io/tracking-id": "\(env.A):apps/DaemonSet:\(env.NS)/\(env.N)"}},
    status: {desiredNumberScheduled: $d, numberReady: $r, updatedNumberScheduled: $u}}'
}
# daemonsets <DaemonSet>...: while the Lab lists those DaemonSets.
daemonsets() { printf '%s\n' "$@" | jq -s '{items: .}' | kc_answers get daemonsets -A -o json; }

DAEMONSETS="get daemonsets -A -o json"
PLATFORM_APPS="-n argocd get applications -l k3d-lab/group=platform -o json"

@test "join: the Platform's DaemonSets Ready on every node, then its Applications Settled at the Tracked revision's commit" {
  apps "$(app cilium)" "$(app alloy)" "$(app comfyui workloads 0123456789)"
  # A GPU Workload starts in its own time, so the join doesn't wait for it.
  daemonsets "$(daemonset kube-system/cilium cilium 3 3 3)" "$(daemonset comfyui/comfyui comfyui 1 0 1)"
  run settle_join
  [[ $status -eq 0 && $output == *"${main_commit:0:7}"* ]]
  in_order "$PLATFORM_APPS" "$DAEMONSETS" "$APPS"
}

@test "join: a Platform DaemonSet not Ready, or not up to date, at the deadline: fails naming it" {
  apps "$(app cilium)" "$(app alloy)"
  daemonsets "$(daemonset kube-system/cilium cilium 3 2 3)" "$(daemonset monitoring/alloy alloy 3 3 2)" \
    "$(jq -n '{metadata: {name: "fresh", namespace: "monitoring", annotations: {"argocd.argoproj.io/tracking-id": "alloy:apps/DaemonSet:monitoring/fresh"}}}')"
  give_up_at_once
  run settle_join
  [[ $status -eq 1 && $output == *"error: these DaemonSets aren't Ready on every node after 3 minutes:
kube-system/cilium: 2 of 3 Ready, 3 up to date
monitoring/alloy: 3 of 3 Ready, 2 up to date
monitoring/fresh: not counted yet" ]]
}

@test "join: a Platform Application not Settled at the deadline: fails naming it" {
  apps "$(app cilium)" "$(app alloy platform 0123456789)"
  daemonsets "$(daemonset kube-system/cilium cilium 3 3 3)"
  give_up_at_once
  run settle_join
  [[ $status -eq 1 && $output == *"error: these Applications aren't Settled after 3 minutes:
alloy: synced at 0123456" ]]
}

@test "join: a Platform Application paused: fails before waiting, naming only it" {
  apps "$(app cilium)" "$(app comfyui workloads)"
  projects cilium comfyui
  run settle_join
  [[ $status -eq 1 && $output == *"error: paused, so they'd never be Settled: cilium; 'just resume <name>' each first" ]]
  ! grep -qF -- "$DAEMONSETS" "$KC_CALLS"
}

# k3d_nodes <ready>: while the Lab lists its two k3d Nodes, both with that Ready status.
k3d_nodes() {
  jq -n --arg r "$1" '{items: ["k3d-lab-server-0", "k3d-lab-agent-0"] |
    map({metadata: {name: .}, status: {conditions: [{type: "Ready", status: $r}]}})}' |
    kc_answers get nodes -o json -l '!k3d-lab/gpu'
}
K3D_NODES="get nodes -o json -l !k3d-lab/gpu"

@test "start: the k3d Nodes Ready, then every Application refreshed, then Settled but those paused" {
  k3d_nodes True
  kc_succeeds $REFRESH_ALL
  apps "$(app root)" "$(app cilium)" "$(app comfyui workloads | jq '.status.health.status = "Degraded"')"
  projects comfyui
  run settle_start
  [[ $status -eq 0 && $output == *"but those paused: comfyui"* ]]
  in_order "$K3D_NODES" "$REFRESH_ALL" "$APPS"
}

@test "start: an Application not Settled at the deadline: fails naming it" {
  k3d_nodes True
  kc_succeeds $REFRESH_ALL
  apps "$(app root)" "$(app cilium | jq '.status.health.status = "Progressing"')"
  give_up_at_once
  run settle_start
  [[ $status -eq 1 && $output == *"error: these Applications aren't Settled after 10 minutes:
cilium: "* ]]
}

@test "start: a k3d Node not Ready at the deadline: fails before reading the Applications" {
  k3d_nodes False
  give_up_at_once
  run settle_start
  [[ $status -eq 1 && $output == *"error: these nodes aren't Ready after 5 minutes:
k3d-lab-server-0: NotReady"* ]]
  ! grep -qF -- "$APPS" "$KC_CALLS"
}

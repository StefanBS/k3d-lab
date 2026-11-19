# The component folders, one ArgoCD Application each: what their component.yaml says,
# and what it may say. Sourced by lib.sh, and on its own by scripts/tests/, so it sets no
# shell options and runs nothing when sourced. Every path is under LAB_ROOT.
# shellcheck shell=bash
# shellcheck disable=SC2034  # DEMO_LABEL_KEY and FEATURE_LABEL_KEY are used by the scripts that source this file

# Every component folder, as <group>/<name>: one ArgoCD Application each.
component_dirs() {
  local file
  for file in "$LAB_ROOT"/{platform,workloads}/*/component.yaml; do
    [[ -f $file ]] || continue # an empty group leaves its glob unexpanded
    file=${file#"$LAB_ROOT"/}
    echo "${file%/component.yaml}"
  done
}

# The Demos, the Workloads with `role: demo` in their component.yaml, as component_dirs
# prints them. A Lab has them only when asked for: `just up --demos`, `just demos on`.
demo_dirs() {
  local dir
  while read -r dir; do
    if [[ $dir == workloads/* && $(yq '.role' "$LAB_ROOT/$dir/component.yaml") == demo ]]; then echo "$dir"; fi
  done < <(component_dirs)
}
# The checks of a Demo carry this label, with the Demo's name: they run only while the Lab
# has its Demos (verify.sh).
DEMO_LABEL_KEY=k3d-lab/demo

# Whether a component folder installs a chart; otherwise its kustomization.yaml is the
# component (the Platform and Workloads ApplicationSets decide the same way).
component_has_chart() { [[ $(yq 'has("chart")' "$LAB_ROOT/$1/component.yaml") == true ]]; }

# The arguments that make `helm template` or `helm upgrade --install` render a component
# the way ArgoCD does: its pinned chart, namespace and values. One per line, for mapfile.
component_helm_args() {
  local dir=$LAB_ROOT/$1
  local component=$dir/component.yaml
  printf '%s\n' \
    "$(yq '.chart' "$component")" \
    --repo "$(yq '.repoURL' "$component")" \
    --version "$(yq '.version' "$component")" \
    --namespace "$(component_namespace "$1")" \
    --values "$dir/values.yaml"
}

# component_namespace <group>/<name>: the namespace that component folder installs into.
component_namespace() { yq '.namespace' "$LAB_ROOT/$1/component.yaml"; }

# component_wave <group>/<name>: the Wave a Platform component is installed in, or
# nothing when it sets none. One that sets none is installed after every Wave.
component_wave() { yq '.wave // ""' "$LAB_ROOT/$1/component.yaml"; }

# component_feature <group>/<name>: the Feature a component is in, or nothing when it's in
# none, so every Lab has it.
component_feature() { yq '.feature // ""' "$LAB_ROOT/$1/component.yaml"; }

# The Features, the sets of components a Lab can be built without, as gitops/values.yaml
# lists them, one per line.
features() { yq '.features[]' "$LAB_ROOT/gitops/values.yaml"; }

# feature_dirs <feature>: the component folders in that Feature, as component_dirs prints
# them.
feature_dirs() {
  local dir
  while read -r dir; do
    if [[ $(component_feature "$dir") == "$1" ]]; then echo "$dir"; fi
  done < <(component_dirs)
}

# The checks of a Feature's components carry this label, with the Feature's name: they run
# only while the Lab has it (verify.sh).
FEATURE_LABEL_KEY=k3d-lab/feature

# without_features <names>: the Features a Lab is to be built without, from a
# comma-separated list such as `just up --without` takes, one per line, in the order
# given. `none`, or nothing, is every Feature, so it prints nothing. Fails, saying why on
# stderr, on a name that isn't a Feature, before anything is built.
without_features() {
  local names name known=() without=() unknown=()
  [[ -n $1 && $1 != none ]] || return 0
  mapfile -t known < <(features)
  # A trailing comma leaves no empty name behind; read drops it.
  IFS=, read -ra names <<<"$1"
  for name in "${names[@]}"; do
    if [[ -z $name || " ${known[*]} " != *" $name "* ]]; then
      unknown+=("'$name'")
    elif [[ " ${without[*]} " != *" $name "* ]]; then
      without+=("$name")
    fi
  done
  if ((${#unknown[@]})); then
    echo "not a Feature: ${unknown[*]}; the Features are ${known[*]}, or none for every one" >&2
    return 1
  fi
  ((${#without[@]} == 0)) || printf '%s\n' "${without[@]}"
}

# components_problems: prints each way the component folders break what the
# ApplicationSets expect of them, one per line, or nothing.
components_problems() {
  local dirs duplicates dir namespace
  mapfile -t dirs < <(component_dirs)
  if ((${#dirs[@]} == 0)); then
    echo "no component folders found"
    return
  fi
  # Each folder's name is its Application's name, and those share one namespace.
  duplicates=$(printf '%s\n' "${dirs[@]##*/}" | sort | uniq -d)
  [[ -z $duplicates ]] || echo "component names used twice: $(paste -sd' ' <<<"$duplicates")"
  for dir in "${dirs[@]}"; do _component_problems "$dir"; done
  _waves_problems "${dirs[@]}"
  _features_problems
  for namespace in $(yq '.platformNamespaces[]' "$LAB_ROOT/gitops/values.yaml" | sort | uniq -d); do
    echo "gitops/values.yaml: platformNamespaces lists $namespace twice"
  done
}

# _features_problems: gitops/values.yaml lists each Feature once, and a Lab is built
# without only Features it lists. `none` is what `just up --without` takes for every
# Feature, so it can't name one.
_features_problems() {
  local feature known
  known=$(features)
  for feature in $(sort <<<"$known" | uniq -d); do
    echo "gitops/values.yaml: features lists $feature twice"
  done
  if grep -qxF none <<<"$known"; then echo "gitops/values.yaml: no Feature can be named none"; fi
  for feature in $(yq '.without[]' "$LAB_ROOT/gitops/values.yaml"); do
    grep -qxF -- "$feature" <<<"$known" || echo "gitops/values.yaml: without names $feature, which isn't one of its features"
  done
}

# _waves_problems <group>/<name>...: the root Application's sync would wait forever for an
# ApplicationSet with no component to be Healthy (platform/argocd/values.yaml), so each
# Wave gitops/values.yaml lists has a Platform component. So does the Platform's last
# ApplicationSet, which gets the components that set no Wave. Each keeps one in no
# Feature, which a Lab built without every Feature still has.
_waves_problems() {
  local dir wave waves=() kept=() last=false last_kept=false
  for dir; do
    [[ $dir == platform/* ]] || continue
    wave=$(component_wave "$dir")
    if [[ -n $wave ]]; then
      waves+=("$wave")
      [[ -n $(component_feature "$dir") ]] || kept+=("$wave")
    else
      last=true
      [[ -n $(component_feature "$dir") ]] || last_kept=true
    fi
  done
  for wave in $(yq '.platformWaves[]' "$LAB_ROOT/gitops/values.yaml"); do
    if [[ " ${waves[*]} " != *" $wave "* ]]; then
      echo "gitops/values.yaml: no Platform component is in the Wave $wave"
    elif [[ " ${kept[*]} " != *" $wave "* ]]; then
      echo "gitops/values.yaml: every Platform component in the Wave $wave is in a Feature, which leaves its ApplicationSet with none in a Lab without them"
    fi
  done
  if [[ $last != true ]]; then
    echo "gitops/values.yaml: every Platform component sets a Wave, which leaves the Platform's last ApplicationSet with none"
  elif [[ $last_kept != true ]]; then
    echo "gitops/values.yaml: every Platform component that sets no Wave is in a Feature, which leaves the Platform's last ApplicationSet with none in a Lab without them"
  fi
}

# _component_problems <group>/<name>: the ApplicationSets template these fields into the
# component's Application.
_component_problems() {
  local dir=$1 key only wave waves feature keys=(namespace) file=kustomization.yaml
  local component=$LAB_ROOT/$1/component.yaml
  if component_has_chart "$dir"; then
    keys+=(repoURL version)
    file=values.yaml
  fi
  for key in "${keys[@]}"; do
    # -e: fails when the key is missing or null.
    yq -e ".$key" "$component" >/dev/null 2>&1 || echo "$dir/component.yaml: '$key' is missing"
  done
  [[ -f $LAB_ROOT/$dir/$file ]] || echo "$dir/$file is missing"
  _namespace_problems "$dir"
  # Optional, and only a Platform component's: the Wave its ApplicationSet installs it
  # in, one that gitops/values.yaml lists.
  wave=$(component_wave "$dir")
  if [[ -n $wave ]]; then
    if [[ $dir != platform/* ]]; then
      echo "$dir/component.yaml: only a Platform component sets 'wave'"
    else
      # Captured first: under pipefail, `yq | grep -q` fails when grep stops yq early.
      waves=$(yq '.platformWaves[]' "$LAB_ROOT/gitops/values.yaml")
      grep -qxF -- "$wave" <<<"$waves" ||
        echo "$dir/component.yaml: 'wave' isn't one of gitops/values.yaml's platformWaves"
    fi
  fi
  # Optional: the Feature it's in, one that gitops/values.yaml lists, which every
  # ApplicationSet leaves out of a Lab built without it.
  feature=$(component_feature "$dir")
  if [[ -n $feature ]] && ! grep -qxF -- "$feature" <<<"$(features)"; then
    echo "$dir/component.yaml: 'feature' isn't one of gitops/values.yaml's features"
  fi
  # Optional, and only a Workload's: the workloads ApplicationSet labels its namespace by
  # `isolation`, and leaves a `role: demo` out of a Lab that wasn't asked for its Demos.
  for only in isolation=strict role=demo; do
    key=${only%=*}
    [[ $(yq "has(\"$key\")" "$component") == true ]] || continue
    if [[ $dir != workloads/* ]]; then
      echo "$dir/component.yaml: only a Workload sets '$key'"
    elif [[ $(yq ".$key" "$component") != "${only#*=}" ]]; then
      echo "$dir/component.yaml: '$key' can only be '${only#*=}'"
    fi
  done
}

# _namespace_problems <group>/<name>: the gitops chart can't read component.yaml, so
# gitops/values.yaml lists the Platform's namespaces itself, for the workloads project to
# refuse. Each Platform component's is listed, and no Workload's. Lint checks the
# namespaces a Platform component's render creates or installs into.
_namespace_problems() {
  local dir=$1 namespace namespaces listed=false
  namespace=$(component_namespace "$dir")
  [[ $namespace != null ]] || return 0 # _component_problems names it missing
  # Captured first: under pipefail, `yq | grep -q` fails when grep stops yq early.
  namespaces=$(yq '.platformNamespaces[]' "$LAB_ROOT/gitops/values.yaml")
  if grep -qxF -- "$namespace" <<<"$namespaces"; then listed=true; fi
  if [[ $dir == platform/* && $listed == false ]]; then
    echo "$dir/component.yaml: its namespace $namespace isn't in gitops/values.yaml's platformNamespaces"
  elif [[ $dir == workloads/* && $listed == true ]]; then
    echo "$dir/component.yaml: its namespace $namespace is one of gitops/values.yaml's platformNamespaces"
  fi
}

# What verify's checks read from Git instead of copying it: the Platform facts, the
# namespaces they name, and the labels verify.sh selects them by. verify.sh exports them
# to the checks, and lint finds the copies left in verify/. Lint also finds the Demos'
# checks that lack the label verify.sh deselects them by. Sourced by verify.sh and
# lint.sh, and on its own by scripts/tests/, so it sets no shell options and runs nothing
# when sourced. Every path is under LAB_ROOT.
# shellcheck shell=bash

# The namespaces verify's checks name, which verify.sh exports as VERIFY_NS_<KEY>: each
# key's namespace is its component's.
declare -gA VERIFY_NAMESPACES=(
  [monitoring]=platform/prometheus
  [sso]=platform/dex
  [argocd]=platform/argocd
)

# verify_export: exports what the checks read, for Chainsaw to pass on to their script
# steps, and to env() in their resources: each Platform fact, as platform_fact_variable
# names it, each of VERIFY_NAMESPACES, and the GPU Node's label, as
# VERIFY_GPU_NODE_LABEL_KEY and _VALUE. Fails if a fact doesn't resolve, saying which.
verify_export() {
  local name value
  for name in "${!PLATFORM_FACTS[@]}"; do
    value=$(platform_fact "$name") || return
    export "$(platform_fact_variable "$name")=$value"
  done
  for name in "${!VERIFY_NAMESPACES[@]}"; do
    value=$(component_namespace "${VERIFY_NAMESPACES[$name]}") || return
    export "$(verify_namespace_variable "$name")=$value"
  done
  export VERIFY_GPU_NODE_LABEL_KEY=$GPU_NODE_LABEL_KEY VERIFY_GPU_NODE_LABEL_VALUE=${GPU_NODE_LABEL#*=}
}

# verify_copies_problems: prints each copy in verify/ of what verify.sh exports, each
# label of a check's that verify.sh doesn't select by, and each variable read there
# that it doesn't export, as "<file>:<line> ...", one per line in the files' order, or
# nothing.
verify_copies_problems() {
  _verify_copies | sort -t: -k1,1 -k2,2n
}

_verify_copies() {
  local name value hit file line exported
  for name in "${!PLATFORM_FACTS[@]}"; do
    value=$(_platform_fact "$name") || continue # platform_facts_problems reports it.
    # A URL's host is a copy too, whatever its scheme.
    value=${value#*://}
    # Only where it stands alone: a name, such as a ServiceAccount's, can also be part of
    # a longer one, such as an API group's, or a host's under it.
    while IFS= read -r hit; do
      echo "$(cut -d: -f1,2 <<<"$hit") copies the Platform fact $name ($value); read \$$(platform_fact_variable "$name")"
    done < <(cd "$LAB_ROOT" && grep -rnP -- "(?<![\w.-])\Q$value\E(?![\w-]|\.\w)" verify)
  done
  for name in "${!VERIFY_NAMESPACES[@]}"; do
    value=$(component_namespace "${VERIFY_NAMESPACES[$name]}")
    # As kubectl, YAML, the API's paths, a Service's name and JMESPath take it, and as
    # prose says it. A namespace's name may be part of a longer one, or of a word.
    while IFS= read -r hit; do
      echo "$(cut -d: -f1,2 <<<"$hit") names the namespace $value; read \$$(verify_namespace_variable "$name")"
    done < <(cd "$LAB_ROOT" && grep -rnE -- "(-n |--namespace[ =]|namespace:? |namespaces/)$value([^a-z0-9-]|\$)|\.$value\.svc|'$value'" verify)
  done
  _verify_label_copies
  # A renamed fact or namespace leaves its old variable unset, which no copy shows.
  exported=$(_verify_variables)
  while IFS=: read -r file line name; do
    grep -qxF -- "$name" <<<"$exported" || echo "$file:$line reads $name, which verify.sh doesn't export"
  done < <(cd "$LAB_ROOT" && grep -rnoE -- '(PLATFORM_FACT|VERIFY)_[A-Z0-9_]+' verify)
}

# The names of the variables verify_export exports, one per line.
_verify_variables() {
  local name
  for name in "${!PLATFORM_FACTS[@]}"; do platform_fact_variable "$name"; done
  for name in "${!VERIFY_NAMESPACES[@]}"; do verify_namespace_variable "$name"; done
  printf '%s\n' VERIFY_GPU_NODE_LABEL_KEY VERIFY_GPU_NODE_LABEL_VALUE
}

# Chainsaw can't template a check's own labels, which verify.sh's --selector reads, so
# they're the one place the labels' keys are written out: each one is checked here.
_verify_label_copies() {
  local test file line key value hit labels=""
  for test in "$LAB_ROOT"/verify/*/chainsaw-test.yaml; do
    file=${test#"$LAB_ROOT"/}
    while IFS=$'\t' read -r line key value; do
      [[ -n $line ]] || continue # a check with no labels
      labels+="$file:$line"$'\n'
      [[ $key=$value == "$GPU_NODE_LABEL" || $key == "$DEMO_LABEL_KEY" ]] && continue
      echo "$file:$line is labelled $key=$value, which verify.sh doesn't select by: label it $GPU_NODE_LABEL or $DEMO_LABEL_KEY"
    done < <(yq '.metadata.labels[] | [line, key, .] | @tsv' "$test")
  done
  while IFS= read -r hit; do
    grep -qxF -- "${hit%:*}" <<<"$labels" ||
      echo "${hit%:*} copies the GPU Node's label key $GPU_NODE_LABEL_KEY; read \$VERIFY_GPU_NODE_LABEL_KEY"
  done < <(cd "$LAB_ROOT" && grep -rnoF -- "$GPU_NODE_LABEL_KEY" verify)
}

# demo_checks_problems: prints each check that names a Demo's namespace, itself or in a
# script it runs from verify/lib/, but isn't labelled DEMO_LABEL_KEY, one per line, or
# nothing. Such a check fails on a Lab without its Demos, where verify deselects only the
# labelled ones.
demo_checks_problems() {
  local dir namespace test files
  for dir in $(demo_dirs); do
    namespace=$(component_namespace "$dir")
    for test in "$LAB_ROOT"/verify/*/chainsaw-test.yaml; do
      mapfile -t files < <(grep -o '\.\./lib/[A-Za-z0-9._-]*' "$test" | sort -u)
      files=("${files[@]/#..\//$LAB_ROOT/verify/}")
      grep -qw -- "$namespace" "$test" "${files[@]}" || continue
      [[ $(KEY=$DEMO_LABEL_KEY yq '.metadata.labels | has(strenv(KEY))' "$test") == true ]] && continue
      echo "${test#"$LAB_ROOT"/} names the Demo's namespace $namespace, but isn't labelled $DEMO_LABEL_KEY"
    done
  done
}

# verify_namespace_variable <key>: the variable verify.sh exports that key of
# VERIFY_NAMESPACES as, such as VERIFY_NS_ARGOCD for argocd.
verify_namespace_variable() { echo "VERIFY_NS_${1^^}"; }

# platform_fact_variable <name>: the variable verify.sh exports that fact as, such as
# PLATFORM_FACT_ARGOCD_HOST for argocd.host.
platform_fact_variable() {
  local variable=PLATFORM_FACT_${1^^}
  echo "${variable//[.-]/_}"
}

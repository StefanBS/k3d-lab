#!/usr/bin/env bats
# The health ArgoCD gives an ApplicationSet (platform/argocd/values.yaml), which the root
# Application's sync waits on between the Platform's waves, without a Lab: the check runs
# in ArgoCD's own CLI, against an ApplicationSet with the conditions and Applications given.

setup_file() {
  local values=$BATS_TEST_DIRNAME/../../platform/argocd/values.yaml
  export ARGOCD_CM=$BATS_FILE_TMPDIR/argocd-cm.yaml
  yq '{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "argocd-cm", "namespace": "argocd"},
    "data": (.configs.cm | with_entries(select(.key == "resource.customizations.health.argoproj.io_ApplicationSet")))}' \
    "$values" >"$ARGOCD_CM"
  [[ $(yq '.data | length' "$ARGOCD_CM") == 1 ]]
}

# applicationset [<ResourcesUpToDate status>] [--error] [<Application>=<health>...]: an
# ApplicationSet with that condition, or none, ErrorOccurred when --error is given, and
# those Applications in its status, a health of "" being none.
applicationset() {
  local uptodate=${1:-} error=False app
  (($#)) && shift
  if [[ ${1:-} == --error ]]; then
    error=True
    shift
  fi
  {
    echo 'apiVersion: argoproj.io/v1alpha1'
    echo 'kind: ApplicationSet'
    echo 'metadata: {name: platform, namespace: argocd}'
    echo 'status:'
    echo '  conditions:'
    echo "    - {type: ErrorOccurred, status: \"$error\", message: the generator failed}"
    [[ -z $uptodate ]] || echo "    - {type: ResourcesUpToDate, status: \"$uptodate\", message: an Application failed to update}"
    echo '  resources:'
    [[ $# -gt 0 ]] || echo '    []'
    for app; do
      if [[ -n ${app#*=} ]]; then
        echo "    - {name: ${app%=*}, health: {status: ${app#*=}}}"
      else
        echo "    - {name: ${app%=*}}"
      fi
    done
  } >"$BATS_TEST_TMPDIR/applicationset.yaml"
}

# expect <status> <message>: the health ArgoCD gives the ApplicationSet last written.
expect() {
  local out got
  out=$(argocd admin settings resource-overrides health "$BATS_TEST_TMPDIR/applicationset.yaml" \
    --argocd-cm-path "$ARGOCD_CM" 2>/dev/null)
  got=$(sed -n 's/^STATUS: //p; s/^MESSAGE: //p' <<<"$out" | paste -sd '|')
  [[ $got == "$1|$2" ]] || {
    echo "want: $1|$2"
    echo "got:  $got"
    echo "$out"
    return 1
  }
}

@test "every Application Healthy: Healthy" {
  applicationset True a=Healthy b=Healthy
  expect Healthy "Every Application is Healthy"
}

@test "an Application not Healthy yet: Progressing, naming it" {
  applicationset True a=Healthy b=Progressing c=Healthy
  expect Progressing "Waiting for b, which is Progressing"
}

@test "a Degraded Application: Progressing, since it retries" {
  applicationset True a=Degraded
  expect Progressing "Waiting for a, which is Degraded"
}

@test "an Application with no health yet: Progressing, as Unknown" {
  applicationset True a=
  expect Progressing "Waiting for a, which is Unknown"
}

@test "up to date but listing no Applications, as its first status can: Progressing" {
  applicationset True
  expect Progressing "Waiting for the Applications to be listed"
}

@test "no ResourcesUpToDate yet: Progressing" {
  applicationset "" a=Healthy
  expect Progressing "Waiting for the Applications to be generated"
}

@test "ResourcesUpToDate False: Degraded, with its message" {
  applicationset False a=Healthy
  expect Degraded "an Application failed to update"
}

@test "ErrorOccurred: Degraded, with its message, even with every Application Healthy" {
  applicationset True --error a=Healthy
  expect Degraded "the generator failed"
}

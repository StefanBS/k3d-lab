# The root Application: its manifest, changing it, and what it says. Sourced by lib.sh,
# and on its own by scripts/tests/, so it sets no shell options and runs nothing when
# sourced.
# shellcheck shell=bash

# root_application_patch [--revision <branch or tag>] [--demos true|false]: prints the
# merge patch that sets those fields of the root Application.
#   --revision  The Tracked revision, set twice: the root Application's own, and the one
#               its chart gives every Application it generates.
#   --demos     Whether the Lab has its Demos: the workloads ApplicationSet leaves them
#               out while it's false.
# Fails, printing no patch, on no options, an empty revision, or a --demos that isn't
# true or false: a patch that changes nothing, or blanks a field, is a caller's mistake.
root_application_patch() {
  local revision='' demos=''
  (($#)) || return 1
  while (($#)); do
    case $1 in
      --revision)
        revision=${2-}
        [[ -n $revision ]] || return 1
        shift 2
        ;;
      --demos)
        demos=${2-}
        [[ $demos == true || $demos == false ]] || return 1
        shift 2
        ;;
      *) return 1 ;;
    esac
  done
  # shellcheck disable=SC2016 # The $ names are jq variables, not the shell's.
  jq -n --arg revision "$revision" --arg demos "$demos" '{}
    | if $revision != "" then
        .spec.source.targetRevision = $revision |
        .spec.source.helm.valuesObject.revision = $revision
      end
    | if $demos != "" then .spec.source.helm.valuesObject.demos = ($demos == "true") end'
}

# root_application_manifest <revision> <demos>: prints the root Application that up.sh
# applies, reading the Lab from LAB_REPO at that revision, with or without the Demos
# (true or false). The fields a patch can change come from root_application_patch, so
# each has one path in the code. Fails, printing nothing, as the patch does.
root_application_manifest() {
  local patch
  patch=$(root_application_patch --revision "$1" --demos "$2") || return 1
  PATCH=$patch yq -P '. * (strenv(PATCH) | from_yaml)' <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: $LAB_REPO
    path: gitops
    helm:
      valuesObject:
        repoURL: $LAB_REPO
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
  # The sync windows that 'just pause' adds to a project stay, until 'just resume'. Git
  # sets none, so the whole list is left to the Lab: a window added in Git would not apply.
  ignoreDifferences:
    - group: argoproj.io
      kind: AppProject
      jsonPointers:
        - /spec/syncWindows
EOF
}

# lab_has_demos: reads the root Application (kubectl get application/root -o json) on stdin,
# and prints true if the Lab has its Demos, false otherwise.
lab_has_demos() {
  # input fails when there's nothing to read, where a plain filter would print nothing.
  jq -rn 'input | .spec.source.helm.valuesObject.demos == true'
}

# For the scripts that patch the root Application, which up.sh creates last.
need_root_application() {
  need_lab
  kc -n argocd get application/root >/dev/null 2>&1 || die "the Lab has no root Application; run 'just down', then 'just up'"
}
# root_application_track <branch or tag>: makes it the Lab's Tracked revision.
root_application_track() { root_application_change --revision "$1"; }
# root_application_set_demos true|false: whether the Lab has its Demos.
root_application_set_demos() { root_application_change --demos "$1"; }
# root_application_change <root_application_patch option>...: patches the root
# Application, with a hard refresh, so ArgoCD renders it again now rather than at its
# next poll, also when the Tracked revision is the same branch at a new commit.
root_application_change() {
  local patch
  patch=$(root_application_patch "$@") || die "no patch for the root Application from: $*"
  jq '.metadata.annotations."argocd.argoproj.io/refresh" = "hard"' <<<"$patch" |
    kc -n argocd patch application/root --type merge --patch-file /dev/stdin >/dev/null
}
# root_application_has_demos: prints true if the Lab has its Demos, false otherwise.
root_application_has_demos() {
  local root
  root=$(kc -n argocd get application/root -o json) || die "can't read the Lab's root Application"
  lab_has_demos <<<"$root"
}
# tracked_commit: prints the commit LAB_REPO has now for the root Application's Tracked
# revision, the one every Application is Settled at. Fails as pushed_commit does.
tracked_commit() {
  local revision
  revision=$(kc -n argocd get application/root -o 'jsonpath={.spec.source.targetRevision}') ||
    die "can't read the Lab's root Application"
  pushed_commit "$revision"
}

# The repo ArgoCD builds the Lab from, and the commit it has for a branch or tag. Sourced
# by lib.sh, and on its own by scripts/tests/, so it sets no shell options and runs
# nothing when sourced.
# shellcheck shell=bash
# shellcheck disable=SC2034  # LAB_REPO is used by the scripts that source this file

# ArgoCD reads the Lab from here, without credentials.
LAB_REPO=https://github.com/StefanBS/k3d-lab.git

# pushed_commit <branch or tag>: prints the commit LAB_REPO has for it, the one ArgoCD
# reads, and fails if LAB_REPO doesn't have it. verify runs the checks as they are here,
# so it warns when the branch checked out here isn't that commit.
pushed_commit() {
  local revision=$1 commit
  # An annotated tag is listed twice: as itself, then peeled (^{}) to its commit, which
  # is what ArgoCD records. A branch comes first, as ArgoCD prefers it too.
  commit=$(git ls-remote "$LAB_REPO" "refs/heads/$revision" "refs/tags/$revision" "refs/tags/$revision^{}" |
    awk -v branch="refs/heads/$revision" -v tag="refs/tags/$revision" '
      $2 == branch { b = $1 }
      $2 == tag "^{}" { peeled = $1 }
      $2 == tag { plain = $1 }
      END { print (b != "" ? b : peeled != "" ? peeled : plain) }')
  [[ -n $commit ]] || die "'$revision' isn't a branch or tag of $LAB_REPO; push it first"
  if [[ $revision == "$(git -C "$LAB_ROOT" branch --show-current)" &&
    $commit != "$(git -C "$LAB_ROOT" rev-parse HEAD)" ]]; then
    log "warning: $revision here isn't the commit $LAB_REPO has; the Lab runs what's pushed"
  fi
  echo "$commit"
}

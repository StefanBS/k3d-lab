#!/usr/bin/env bats
# The commit LAB_REPO has for a branch or tag (scripts/lib/lab-repo.sh), the one ArgoCD
# reads, without the remote: git answers ls-remote from REFS, and the checkout here is on
# BRANCH at HEAD.

setup() {
  # lab sources lab-repo.sh.
  load lab
  LAB_ROOT=$BATS_TEST_TMPDIR/repo
  REFS=''
  BRANCH=main
  HEAD=aaa
}

# git stands in for the three calls pushed_commit makes: ls-remote of LAB_REPO, which
# prints the lines of REFS that name a ref it was asked for, as the real one does, and
# the branch and commit checked out at LAB_ROOT.
git() {
  case "$*" in
    "ls-remote $LAB_REPO "*)
      local ref
      shift 2
      for ref; do awk -v ref="$ref" '$2 == ref' <<<"$REFS"; done
      ;;
    "-C $LAB_ROOT branch --show-current") echo "$BRANCH" ;;
    "-C $LAB_ROOT rev-parse HEAD") echo "$HEAD" ;;
    *) return 1 ;;
  esac
}

@test "a branch: its commit" {
  REFS=$'bbb\trefs/heads/my-branch'
  run pushed_commit my-branch
  [[ $status -eq 0 ]]
  [[ $output == bbb ]]
}

@test "a branch and a tag of the same name: the branch's, as ArgoCD prefers it" {
  REFS=$'ttt\trefs/tags/v1\nbbb\trefs/heads/v1'
  run pushed_commit v1
  [[ $status -eq 0 ]]
  [[ $output == bbb ]]
}

@test "an annotated tag: the commit it's peeled to, which ArgoCD records" {
  REFS=$'ttt\trefs/tags/v1\nccc\trefs/tags/v1^{}'
  run pushed_commit v1
  [[ $status -eq 0 ]]
  [[ $output == ccc ]]
}

@test "a lightweight tag: its commit" {
  REFS=$'ccc\trefs/tags/v1'
  run pushed_commit v1
  [[ $status -eq 0 ]]
  [[ $output == ccc ]]
}

@test "neither: fails, saying to push it" {
  run pushed_commit my-branch
  [[ $status -eq 1 ]]
  [[ $output == "error: 'my-branch' isn't a branch or tag of $LAB_REPO; push it first" ]]
}

@test "the branch checked out here, at another commit: warns, since the Lab runs what's pushed" {
  REFS=$'bbb\trefs/heads/main'
  run pushed_commit main
  [[ $status -eq 0 ]]
  [[ $output == "==> warning: main here isn't the commit $LAB_REPO has; the Lab runs what's pushed
bbb" ]]
}

@test "the branch checked out here, at the pushed commit: no warning" {
  REFS=$'bbb\trefs/heads/main'
  HEAD=bbb
  run pushed_commit main
  [[ $status -eq 0 ]]
  [[ $output == bbb ]]
}

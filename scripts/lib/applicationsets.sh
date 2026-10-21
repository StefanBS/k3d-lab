# The Lab's ApplicationSets: waiting for them to generate their Applications, and
# refreshing them. Sourced by lib.sh, and on its own by scripts/tests/, so it sets no
# shell options and runs nothing when sourced.
# shellcheck shell=bash

# applicationsets_pending [<name>...]: reads the Lab's ApplicationSets (kubectl get
# applicationsets -o json) on stdin, and prints a line for each whose ResourcesUpToDate
# condition isn't True, as "<name>: not ResourcesUpToDate", with the condition's reason
# when it has one. Without names, every ApplicationSet listed counts; with them, only
# those, and one not listed yet is "not created yet". Without names, a list with none
# prints "no ApplicationSets yet", so it's waited out, not passed. Fails when there's
# nothing to read, as when the request failed.
applicationsets_pending() {
  jq -rn '
    # Why the ApplicationSet on input is pending, or nothing once it is up to date.
    def why:
      [.status.conditions[]? | select(.type == "ResourcesUpToDate")][0] as $condition |
      if $condition.status == "True" then empty
      elif ($condition.reason // "") == "" then "not ResourcesUpToDate"
      else "not ResourcesUpToDate (\($condition.reason))"
      end;
    [input.items[]] as $listed |
    ($listed | map({key: .metadata.name, value: .}) | from_entries) as $by_name |
    if ($ARGS.positional | length) > 0 then
      $ARGS.positional[] as $name | $by_name[$name] |
      if . == null then "\($name): not created yet" else "\($name): \(why)" end
    elif ($listed | length) == 0 then "no ApplicationSets yet"
    else $listed[] | "\(.metadata.name): \(why)"
    end' --args "$@"
}

# wait_applicationsets <seconds> [<name>...]: waits until the Lab's ApplicationSets, or
# only those named, exist and say ResourcesUpToDate, so every Application they generate
# exists. Gives up after that many seconds.
wait_applicationsets() {
  local seconds=$1
  shift
  wait_until_none "$seconds" "these ApplicationSets haven't generated their Applications" \
    applicationsets_in_lab_pending "$@"
}
applicationsets_in_lab_pending() { kc -n argocd get applicationsets -o json | applicationsets_pending "$@"; }

# refresh_applicationsets <seconds>: has every ApplicationSet read Git again now rather
# than at its next poll, as when only the Tracked revision's commit changed, so their spec
# didn't. Waits until the controller has taken every refresh, giving up after that many
# seconds. wait_applicationsets then waits for what they generate.
refresh_applicationsets() {
  kc -n argocd annotate applicationsets --all argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
  wait_until_none "$1" "these ApplicationSets haven't refreshed" applicationsets_in_lab_unrefreshed
}

# applicationsets_unrefreshed: reads the Lab's ApplicationSets (kubectl get
# applicationsets -o json) on stdin, and prints "<name>: refresh not taken yet" for each
# that still has a refresh asked of it: the controller removes the annotation once it has
# taken it. Fails when there's nothing to read, as when the request failed.
applicationsets_unrefreshed() {
  jq -rn 'input.items[] | select(.metadata.annotations["argocd.argoproj.io/application-set-refresh"] != null) |
    "\(.metadata.name): refresh not taken yet"'
}
applicationsets_in_lab_unrefreshed() { kc -n argocd get applicationsets -o json | applicationsets_unrefreshed; }

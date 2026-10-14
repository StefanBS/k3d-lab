# Which of the Lab's ApplicationSets haven't generated their Applications yet. Sourced by
# lib.sh, whose wait_applicationsets waits on it, and on its own by scripts/tests/, so it
# sets no shell options and runs nothing when sourced.
# shellcheck shell=bash

# applicationsets_pending [<name>...]: reads the Lab's ApplicationSets (kubectl get
# applicationsets -o json) on stdin, and prints a line for each whose ResourcesUpToDate
# condition isn't True, as "<name>: not ResourcesUpToDate", with the condition's reason
# when it has one. Without names, every ApplicationSet listed counts; with them, only
# those, and one not listed yet is "not created yet". Fails when there's nothing to read,
# as when the request failed.
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
    if ($ARGS.positional | length) == 0 then $listed[] | "\(.metadata.name): \(why)"
    else
      $ARGS.positional[] as $name | $by_name[$name] |
      if . == null then "\($name): not created yet" else "\($name): \(why)" end
    end' --args "$@"
}

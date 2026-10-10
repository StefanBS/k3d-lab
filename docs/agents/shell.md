# Shell gotchas

Traps in the scripts' tools that cost real debugging time. Each was hit once already.

## awk, yq and jq programs

- A program in single quotes ends at the first `'`, including an apostrophe in a `#` comment or a string inside it: `# the Server's tasks` breaks an awk program. Write around it, such as `the tasks in the Server`.
- CI runs on ubuntu-latest, where awk is mawk. Keep awk to POSIX: no `strftime`, `mktime`, `gensub` or `asort`.

## yq

yq's expressions look like jq's, but these behave differently. For logic over JSON (filtering, picking a reason, joining arrays by index), use `jq`, which mise installs. Use yq for YAML, and for path lookups.

- **A bare string is output even when its input is empty**: `[select(false) | "x"]` gives `["x"]`. An expression that starts from `.`, such as `.metadata.name + ": x"`, drops out as expected.
- There is no `if`/`then`/`else`, and no `empty`.
- `,` binds more loosely than `|`: `x | a, b` is `(x | a), b`. Parenthesize: `x | (a, b)`.
- `$arr[.key]` evaluates `.key` against `$arr`, not the current item. Bind it first: `.key as $i | $arr[$i]`.
- `$var | map(.x = 1)` changes `$var` in place, so a later use of `$var` sees the change.

## bash

- `IFS=$'\t' read -r a b c` merges consecutive tabs, so an empty column shifts every column after it. Print a placeholder for an empty field, or use a delimiter that isn't whitespace.
- `pgrep -f <pattern>` also matches the shell that runs it, when the command line names the pattern: `pgrep -f 'chainsaw test'` in a script always finds a process. Match by name with `pgrep -x chainsaw`, or anchor the pattern at the command line, as `pgrep -f '^below --config'`.
- bash reads a script as it runs it, so an edit to `scripts/up.sh` during a `just up` changes that run. Leave a running script alone until it exits. A file it sourced is already read in full, and safe to edit.
- A bare `wait` waits for every background job of the shell, including a recorder such as `below record` started earlier in the same command, so it blocks until the call times out. Wait for the job you mean: `cmd & pid=$!; ...; wait "$pid"`.

## mise

- `mise -C <repo> exec -- <tool>` runs the tool in the repo root, so whatever it writes to its working directory lands there: `helm pull --untar` unpacks the whole chart into the root (#73). Point the output at a temporary directory, such as `helm pull --untar --untardir "$(mktemp -d)"`. `.gitignore` ignores any top-level entry it doesn't list, so a stray one isn't committed, but it stays on disk.

## kubectl

- `kubectl get <kind> <name> -o json` returns the object, not a List: `.items` is empty. Use `--field-selector metadata.name=<name>` when the code reads `.items`.

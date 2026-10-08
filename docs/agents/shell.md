# Shell gotchas

Traps in the scripts' tools that cost real debugging time. Each was hit once already.

## yq

yq's expressions look like jq's, but these behave differently. For logic over JSON (filtering, picking a reason, joining arrays by index), use `jq`, which mise installs. Use yq for YAML, and for path lookups.

- **A bare string is output even when its input is empty**: `[select(false) | "x"]` gives `["x"]`. An expression that starts from `.`, such as `.metadata.name + ": x"`, drops out as expected.
- There is no `if`/`then`/`else`, and no `empty`.
- `,` binds more loosely than `|`: `x | a, b` is `(x | a), b`. Parenthesize: `x | (a, b)`.
- `$arr[.key]` evaluates `.key` against `$arr`, not the current item. Bind it first: `.key as $i | $arr[$i]`.
- `$var | map(.x = 1)` changes `$var` in place, so a later use of `$var` sees the change.
- A program in single quotes ends at the first `'`, including one in a `#` comment inside it.

## bash

- `IFS=$'\t' read -r a b c` merges consecutive tabs, so an empty column shifts every column after it. Print a placeholder for an empty field, or use a delimiter that isn't whitespace.

## kubectl

- `kubectl get <kind> <name> -o json` returns the object, not a List: `.items` is empty. Use `--field-selector metadata.name=<name>` when the code reads `.items`.

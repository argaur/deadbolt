#!/usr/bin/env bash
# enforcement-check.sh: verify every claim in docs/ENFORCEMENT.md.
# A table that says "these rules are enforced" is prose the moment nobody checks it.
# For each row under "## Enforced" this confirms the named file exists and is not
# empty. That is a weak claim on purpose: it cannot prove a guard works (the tests
# do that). It catches the gap they cannot: a guard deleted or renamed while the
# document keeps claiming it.
#
# Row format: | ID | Rule | `repo/relative/path` |
# A row with no backticked path fails. An executor you cannot locate is not one you
# can verify.
#
# Usage: bash enforcement-check.sh [repo-root]
# Exit:  0 every claim resolves, 1 a claim does not, 2 refused or unparseable

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TABLE="$REPO/docs/ENFORCEMENT.md"

[ -f "$TABLE" ] || { echo "REFUSED: enforcement table not found: $TABLE" >&2; exit 2; }

BLOCK="$(awk '/^## Enforced[[:space:]]*$/{g=1;next} /^## /{if(g)exit} g' "$TABLE")"
[ -n "$BLOCK" ] || { echo "REFUSED: no '## Enforced' section in $TABLE" >&2; exit 2; }

FAIL=0; CHECKED=0; UNPARSED=0

while IFS= read -r row; do
  row="${row%$'\r'}"
  case "$row" in \|*) : ;; *) continue ;; esac
  case "$row" in *'---'*|*'| ID |'*) continue ;; esac

  IFS='|' read -r _ id _ exec_cell _ <<< "$row"
  id="${id// /}"
  [ -n "$id" ] || continue

  spec=""
  rest="${exec_cell#*\`}"
  if [ "$rest" != "$exec_cell" ]; then
    spec="${rest%%\`*}"
    [ "$spec" = "$rest" ] && spec=""
  fi
  if [ -z "$spec" ]; then
    echo "UNPARSEABLE  $id: the Executor cell names no backticked path"
    UNPARSED=1
    continue
  fi

  CHECKED=$((CHECKED+1))
  if [ ! -f "$REPO/$spec" ]; then
    echo "MISSING      $id: claims $spec, which does not exist"
    FAIL=1
  elif [ ! -s "$REPO/$spec" ]; then
    echo "EMPTY        $id: $spec exists but is empty"
    FAIL=1
  fi
done <<< "$BLOCK"

[ "$UNPARSED" = "0" ] || exit 2
if [ "$CHECKED" = "0" ]; then
  echo "REFUSED: parsed zero rows from $TABLE" >&2
  exit 2
fi
if [ "$FAIL" = "0" ]; then
  echo "enforcement-check: clean ($CHECKED enforced claims, every executor present)"
  exit 0
fi
echo "enforcement-check: restore the executor, or downgrade the row. Do not leave the claim standing."
exit 1

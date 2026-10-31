#!/usr/bin/env bash
# stale-doc-check.sh: retired facts must not creep back into live docs.
# A sweep of old facts is a one-time act, and nobody re-greps a doc they believe is
# correct. This is the sweep written as a check, so it stays done.
#
# It reads a `.stale-facts` file at the repo root. One rule per line:
#   <extended regex> ::: <what is true now>
# Blank lines and # comments are skipped. A line `exclude <folder>` skips a folder,
# for history that must keep saying what was true when it was written.
# See examples/stale-facts.example.
#
# Usage: bash stale-doc-check.sh [repo-root]
# Exit:  0 clean, 1 a retired fact is back, 2 refused

set -uo pipefail

REPO="${1:-$PWD}"
RULES="$REPO/.stale-facts"
[ -d "$REPO" ]  || { echo "REFUSED: repo root not found: $REPO" >&2; exit 2; }
[ -f "$RULES" ] || { echo "REFUSED: no .stale-facts file at $REPO" >&2; exit 2; }

EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules)
PATTERNS=(); REASONS=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in
    ''|'#'*) continue ;;
    'exclude '*) EXCLUDES+=("--exclude-dir=${line#exclude }"); continue ;;
    *' ::: '*) PATTERNS+=("${line%% ::: *}"); REASONS+=("${line#* ::: }") ;;
    *) echo "REFUSED: rule has no ' ::: ' separator: $line" >&2; exit 2 ;;
  esac
done < "$RULES"

[ ${#PATTERNS[@]} -gt 0 ] || { echo "REFUSED: .stale-facts holds no rules" >&2; exit 2; }

FAIL=0
for i in "${!PATTERNS[@]}"; do
  rc=0
  hits="$(grep -rEnI --include='*.md' "${EXCLUDES[@]}" -e "${PATTERNS[$i]}" "$REPO" 2>/dev/null)" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "REFUSED: bad regex in .stale-facts: ${PATTERNS[$i]}" >&2
    exit 2
  fi
  if [ -n "$hits" ]; then
    FAIL=1
    echo "STALE: ${REASONS[$i]}"
    printf '%s\n' "$hits" | sed "s|^$REPO/||; s/^/  /"
  fi
done

if [ "$FAIL" = "0" ]; then
  echo "stale-doc-check: clean (${#PATTERNS[@]} retired facts)"
  exit 0
fi
exit 1

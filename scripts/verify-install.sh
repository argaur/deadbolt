#!/usr/bin/env bash
# verify-install.sh: is what is installed still what install.sh put there?
# A commit proves the state of a repo, never the state of ~/.claude. A guard can be
# reverted, or edited by a stray tool, while the repo stays green. This compares the
# installed files with the sha256 manifest written at install time.
#
# Usage: bash verify-install.sh [--quiet]
# Exit:  0 matches, 1 drift or missing file, 2 cannot check

set -uo pipefail

ROOT="$HOME/.claude"
MANIFEST="$ROOT/honest-audits/MANIFEST.sha256"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" = "1" ] || echo "$*"; }

[ -f "$MANIFEST" ] || { say "CANNOT CHECK: no manifest at $MANIFEST. Run install.sh."; exit 2; }

if command -v sha256sum >/dev/null 2>&1; then
  HASH=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  HASH=(shasum -a 256)
else
  say "CANNOT CHECK: neither sha256sum nor shasum is on PATH."
  exit 2
fi

cd "$ROOT" || { say "CANNOT CHECK: cannot enter $ROOT"; exit 2; }

BAD=0; TOTAL=0
while read -r want rel; do
  [ -n "$want" ] || continue
  rel="${rel#\*}"
  TOTAL=$((TOTAL+1))
  if [ ! -f "$rel" ]; then
    say "MISSING  $rel"
    BAD=1
    continue
  fi
  have=$("${HASH[@]}" "$rel" 2>/dev/null); have="${have%% *}"; have="${have#\\}"
  if [ "$have" != "$want" ]; then
    say "DRIFT    $rel"
    BAD=1
  fi
done < "$MANIFEST"

if [ "$TOTAL" = "0" ]; then
  say "CANNOT CHECK: the manifest is empty."
  exit 2
fi
if [ "$BAD" = "0" ]; then
  say "verify-install: clean ($TOTAL files match the manifest)"
  exit 0
fi
say "verify-install: installed files differ from the manifest. Re-run install.sh, or find out who changed them."
exit 1

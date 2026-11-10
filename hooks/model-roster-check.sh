#!/usr/bin/env bash
# model-roster-check.sh: SessionStart hook, part of the optional delegation lane.
# Providers ship and retire models without telling your machine, and models.json has
# no way to refresh itself. Once every 30 days this compares the Google models `agy`
# can see with the roster, in both directions, and asks you to reconcile them.
#
# It never touches its own stamp. The check is finished when a person has reconciled
# the roster, not when this script exits. Until someone runs `touch` on the stamp, it
# fires every session. The nag is the enforcement.
#
# Silent when the stamp is fresh and the roster exists. Always exits 0.

source "$(dirname "${BASH_SOURCE[0]}")/ensure-jq.sh" 2>/dev/null || true
trap 'exit 0' EXIT

BASE="$HOME/.claude/deadbolt"
ROSTER="$BASE/models.json"
STAMP="$BASE/.model-roster-last-check"
STALE_DAYS=30

say() {
  local esc
  esc=$(printf '%s' "$1" | tr -d '[:cntrl:]' | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"systemMessage":"%s"}\n' "$esc"
  exit 0
}

[ -f "$ROSTER" ] || say "MODEL ROSTER MISSING: $ROSTER does not exist, and /delegate reads it."

if [ -f "$STAMP" ]; then
  aged=$(find "$(dirname "$STAMP")" -maxdepth 1 -name "$(basename "$STAMP")" -mtime +"$STALE_DAYS" 2>/dev/null)
  [ -n "$aged" ] || exit 0
fi

FOUND=""
if command -v jq >/dev/null 2>&1 && command -v agy >/dev/null 2>&1; then
  offered=$(timeout 10 agy models 2>/dev/null | tr -d '\r' | awk '/^gemini-/ {print $1}' | sort -u)
  listed=$(jq -r '.providers.google.models[]?.id' "$ROSTER" 2>/dev/null | tr -d '\r' | sort -u)
  excluded=$(jq -r '.providers.google.excluded[]?.id' "$ROSTER" 2>/dev/null | tr -d '\r' | sort -u)
  if [ -n "$offered" ]; then
    offered=$(comm -23 <(printf '%s\n' "$offered") <(printf '%s\n' "$excluded" | sed '/^$/d'))
    added=$(comm -23 <(printf '%s\n' "$offered" | sed '/^$/d') <(printf '%s\n' "$listed" | sed '/^$/d') | tr '\n' ' ')
    gone=$(comm -13 <(printf '%s\n' "$offered" | sed '/^$/d') <(printf '%s\n' "$listed" | sed '/^$/d') | tr '\n' ' ')
    [ -n "$added" ] && FOUND="$FOUND New from Google, not in the roster: $added."
    [ -n "$gone" ]  && FOUND="$FOUND In the roster, no longer offered: $gone."
  fi
fi

say "MODEL ROSTER CHECK DUE (30-day cadence).$FOUND Update $ROSTER against what your providers offer now, then run: touch $STAMP"

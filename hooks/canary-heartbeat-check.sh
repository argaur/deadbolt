#!/usr/bin/env bash
# canary-heartbeat-check.sh: SessionStart hook. Did the canary actually run?
# A silent canary means green, and a canary that never launched is silent too. It
# cannot report itself, so a different hook reads the marker it leaves behind.
# Always exits 0.

MARKER="$HOME/.claude/deadbolt/.canary-last-run"
LIMIT_DAYS=3

say() {
  local esc
  esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
  printf '{"systemMessage":"%s"}\n' "$esc"
  exit 0
}

[ -f "$MARKER" ] || say "HOOK CANARY: no heartbeat at $MARKER. The canary has never run, so no guard has been verified."

mtime=$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER" 2>/dev/null)
now=$(date +%s)
[ -n "$mtime" ] || say "HOOK CANARY: could not read the age of $MARKER, so the heartbeat is unverified."
age=$(( now - mtime ))
[ "$age" -le $(( LIMIT_DAYS * 86400 )) ] || \
  say "HOOK CANARY: last heartbeat is $(( age / 86400 )) days old. The canary may not be running. Check the SessionStart hooks in settings.json."
exit 0

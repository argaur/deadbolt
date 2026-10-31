#!/usr/bin/env bash
# plan-state-check.sh: SessionStart hook. Every project session opens by stating
# where the work stands, read from a `Current phase:` line in the project's
# CLAUDE.md. A project with no such line gets one nudge to add it. This stops a new
# session from guessing the phase, or quietly skipping a gate.
# Always exits 0.

[ "$PWD" = "$HOME" ] && exit 0

FOUND=0
for marker in .git package.json pyproject.toml requirements.txt Makefile go.mod Cargo.toml CLAUDE.md; do
  [ -e "$marker" ] && { FOUND=1; break; }
done
[ "$FOUND" = "1" ] || exit 0

say() {
  local esc
  esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
  printf '{"systemMessage":"%s"}\n' "$esc"
  exit 0
}

if [ -f CLAUDE.md ]; then
  PHASE=$(grep -ioE 'current phase:.*' CLAUDE.md | head -1 | sed 's/\*//g')
  [ -n "$PHASE" ] && say "$PHASE. Resume there. Gates are not skipped, and approval is never assumed."
fi
say "NO PLAN STATE for this project. Before build work, add a 'Current phase:' line to CLAUDE.md, so the next session resumes instead of guessing."

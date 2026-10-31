#!/usr/bin/env bash
# plan-finalized-nudge.sh: PostToolUse hook on Write and ExitPlanMode.
# When a plan is finished, it runs scripts/plan-gate.sh on the plan file and hands
# the result to the model. A PostToolUse hook cannot undo a write, so this informs,
# it does not block. Silent on every other write.
#
# Plan-mode plans fire on ExitPlanMode, because a plan-mode write emits no Write
# event. Direct plans fire on a .md file under a folder named plans.

source "$(dirname "${BASH_SOURCE[0]}")/ensure-jq.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

GATE="$(dirname "${BASH_SOURCE[0]}")/../scripts/plan-gate.sh"
INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null | tr -d '\r')
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null | tr -d '\r')
LOWER="${FILE,,}"; LOWER="${LOWER//\\//}"

IS_PLAN=0
[ "$TOOL" = "ExitPlanMode" ] && IS_PLAN=1
case "$LOWER" in *plans/*.md) IS_PLAN=1 ;; esac
[ "$IS_PLAN" = "1" ] || exit 0

MSG="A plan was just finalized. If it is a multi-step build, tag every step with a model and an effort (see the model-router skill)."
if [ -n "$FILE" ] && [ -f "$FILE" ] && [ -f "$GATE" ]; then
  RESULT=$(bash "$GATE" "$FILE" 2>&1)
  MSG="$MSG plan-gate result: $RESULT"
fi

jq -cn --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' | tr -d '\r'
exit 0

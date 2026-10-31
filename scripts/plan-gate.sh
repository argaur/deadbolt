#!/usr/bin/env bash
# plan-gate.sh: pass or fail on a plan file, before anyone builds from it.
#
# Five checks, all mechanical:
#   1. the plan has at least one checkbox step;
#   2. every checkbox step carries a tag: `[model: NAME, effort: LEVEL]`;
#   3. the plan has an "Out of scope" heading. An unstated exclusion is how scope
#      creep gets back in;
#   4. the plan has a "Verify" heading (Verify, Verification). A plan with no stated
#      check cannot be called done;
#   5. no line carries a hypothesis tag `[H]`, unless the same line also carries
#      `accepted-risk:` with a name. An untested belief does not go into a build
#      unnoticed. Test it, or have someone sign for it.
#
# Usage: bash plan-gate.sh <plan.md>
# Exit:  0 READY, 1 NOT READY, 2 refused (no file)

set -uo pipefail

PLAN="${1:-}"
[ -n "$PLAN" ] || { echo "REFUSED: usage: plan-gate.sh <plan.md>" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "REFUSED: not a file: $PLAN" >&2; exit 2; }

FAILS=()
STEPS=0; TAGGED=0
STEP_RE='^[[:space:]]*[-*][[:space:]]+\[[ xX]\]'
TAG_RE='\[model:[[:space:]]*[A-Za-z0-9._-]+,[[:space:]]*effort:[[:space:]]*[A-Za-z]+\]'
HYP_RE='(^|[^A-Za-z0-9_])\[H\]'
RISK_RE='accepted-risk:[[:space:]]*[^[:space:]]+'

ln=0
while IFS= read -r line || [ -n "$line" ]; do
  ln=$((ln+1))
  line="${line%$'\r'}"
  if [[ $line =~ $STEP_RE ]]; then
    STEPS=$((STEPS+1))
    if [[ $line =~ $TAG_RE ]]; then
      TAGGED=$((TAGGED+1))
    else
      FAILS+=("line $ln: step has no [model: X, effort: Y] tag")
    fi
  fi
  if [[ $line =~ $HYP_RE ]] && ! [[ $line =~ $RISK_RE ]]; then
    FAILS+=("line $ln: [H] hypothesis with no accepted-risk: owner")
  fi
done < "$PLAN"

[ "$STEPS" -gt 0 ] || FAILS+=("no checkbox steps found")
grep -qiE '^#+[[:space:]]+out[- ]of[- ]scope' "$PLAN" || FAILS+=("no 'Out of scope' heading")
grep -qiE '^#+[[:space:]]+verif(y|ication)' "$PLAN"   || FAILS+=("no 'Verify' heading")

if [ ${#FAILS[@]} -eq 0 ]; then
  echo "READY: $STEPS steps, all tagged, scope and verification stated."
  exit 0
fi
echo "NOT READY: ${#FAILS[@]} problem(s). $(printf '%s; ' "${FAILS[@]}")"
exit 1

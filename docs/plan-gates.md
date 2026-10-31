# Plan gates

Most bad builds start as a plan nobody checked. These gates make the checks mechanical.

## plan-gate.sh

Pass or fail on a plan file, before anyone builds from it.

```
bash ~/.claude/honest-audits/scripts/plan-gate.sh plans/my-plan.md
```

It fails a plan when:

- it has no checkbox steps;
- a step has no `[model: X, effort: Y]` tag;
- there is no "Out of scope" heading. An unstated exclusion is how scope creep gets back in;
- there is no "Verify" heading. A plan with no stated check cannot be called done;
- a line carries a hypothesis tag `[H]` with no `accepted-risk: <owner>` on the same line. Test the belief, or have someone sign for it.

## plan-finalized-nudge.sh

Fires when a plan file is written, or plan mode is approved. It runs the gate on the file and hands the result to the model.

A PostToolUse hook cannot undo a write, so this flags a bad plan. It does not block one. For a hard stop, run `plan-gate.sh` in your own build step or CI.

## plan-state-check.sh

Reads `Current phase:` from the project's `CLAUDE.md` at session start, so a new session resumes from a recorded phase instead of guessing. A project with no such line gets a nudge to add one.

## model-router

A skill that tags each plan step with the model and effort that should run it. The tag format is what `plan-gate.sh` checks. Skills are prose, so the gate is what makes the tags real.

The tiers named in the skill are a starting point. Change them to match the models you use.

---
name: model-router
description: Use right before finalizing an implementation plan. Tags every step with the Claude model and effort that should execute it, so a later execution pass knows what to dispatch. Also use when asked to "route models for this plan" or "tag this plan with models".
---

# Model Router

A plan lists what to build. This skill decides which model builds each step, and stamps that decision inline, so execution does not have to re-derive it.

## The buckets

- **opus**: deep analysis and high-stakes judgement. Architecture with real trade-offs, a subtle bug, security-sensitive logic, anything expensive to undo.
- **sonnet**: well-specified execution. Routine development, scripts, tests, boilerplate, most "build it as specified" steps. This is the default.
- **haiku**: small mechanical steps with no judgement. Renames, formatting, lookups.

If a step fits no bucket, tag it `sonnet` and say why in a short comment, so a reviewer can spot the miss. Never leave a step untagged.

## Tag format

Inline at the step header:

```markdown
- [ ] **Step 3: Write the failing test** `[model: sonnet, effort: low]`
- [ ] **Step 7: Design the retry strategy for the webhook** `[model: opus, effort: high]`
```

Effort: `low` for mechanical steps, `medium` for normal implementation, `high` for design, debugging and judgement calls.

`scripts/plan-gate.sh` reads this exact format and fails any step without it. It also needs an "Out of scope" heading, a "Verify" heading, and no `[H]` hypothesis without an `accepted-risk:` owner.

## Process

1. Read the finished plan, every step, in order. Do not tag a partial draft.
2. Classify each step, not each task. "Write the test" and "decide the schema" in one task can differ.
3. Insert the tags. Do not change content, order or scope.
4. Run `bash ~/.claude/deadbolt/scripts/plan-gate.sh <plan.md>`.
5. Report the count per model, plus any fallback tags and their reasons.

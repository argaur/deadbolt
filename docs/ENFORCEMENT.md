# Enforcement table

Every rule this repo claims to enforce, paired with the file that enforces it.

`scripts/enforcement-check.sh` reads the "Enforced" section below and fails if a named file is missing or empty. A table of claims that nobody checks is just more prose.

Tag a row as enforced because you can name the file that stops you, not because the rule matters.

## Enforced

| ID | Rule | Executor |
|---|---|---|
| E01 | No force push. `--force-with-lease` stays allowed | `hooks/pre-tool-use-guard.sh` |
| E02 | No skipping git hooks (`--no-verify`, `git commit -n`) | `hooks/pre-tool-use-guard.sh` |
| E03 | No recursive delete of home or a drive root, in bash, PowerShell or cmd form | `hooks/pre-tool-use-guard.sh` |
| E04 | No `git reset --hard` chained with a push | `hooks/pre-tool-use-guard.sh` |
| E05 | Never print a secret-shaped variable to the transcript | `hooks/pre-tool-use-guard.sh` |
| E06 | Never call `python3` where it is not installed | `hooks/pre-tool-use-guard.sh` |
| E07 | No quoted Windows path that ends in a backslash | `hooks/pre-tool-use-guard.sh` |
| E08 | Never read a secret file through a shell command | `hooks/pre-tool-use-guard.sh` |
| E09 | One shared definition of a secret file, so two guards cannot drift | `hooks/secret-paths.sh` |
| E10 | No `Read` of a secret file, and no content-mode `Grep` on one | `hooks/file-io-guard.sh` |
| E11 | No `Write` that shrinks a memory file below half its size | `hooks/file-io-guard.sh` |
| E12 | No deploy without a recorded `Deploy target:` line | `hooks/deploy-preflight-guard.sh` |
| E13 | Every registered hook exists and parses | `hooks/hook-canary.sh` |
| E14 | Every guard denies a forbidden input and passes a benign one, at every session start | `hooks/hook-canary.sh` |
| E15 | Installed files match the install manifest | `scripts/verify-install.sh` |
| E16 | The canary must really have run, reported by a different hook | `hooks/canary-heartbeat-check.sh` |
| E17 | Retired facts must not creep back into live docs | `scripts/stale-doc-check.sh` |
| E18 | This table's own claims are checked | `scripts/enforcement-check.sh` |
| E19 | A plan has tagged steps, stated scope, stated verification, and no unowned hypothesis | `scripts/plan-gate.sh` |
| E20 | A finished plan is run through the plan gate, and the result reaches the model | `hooks/plan-finalized-nudge.sh` |
| E21 | Every project session states its phase, or is told to record one | `hooks/plan-state-check.sh` |
| E22 | A secret file is never sent to a Google backend | `scripts/agy-delegate.sh` |
| E23 | A secret file is never sent to Codex, and Codex stays read-only | `scripts/codex-delegate.sh` |
| E24 | A stale model roster nags until a person reconciles it | `hooks/model-roster-check.sh` |

## Partial

Something runs, but it covers less than the sentence suggests.

| ID | Rule | Gap |
|---|---|---|
| P01 | A human confirms every Codex call | An `ask` permission rule does this, in `examples/settings.delegate.json`. It only exists if you installed that lane, and a broad allow rule added elsewhere is not checked here |
| P02 | Plan gate before build | The hook reports the result. A PostToolUse hook cannot undo a write, so a failed plan is flagged, not blocked |

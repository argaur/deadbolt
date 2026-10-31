# Delegation (optional)

**You do not need this.** The core repo works without it. It needs a Google Antigravity or OpenAI Codex account and CLI of your own.

`/delegate` sends a read-only task to a non-Anthropic model. A different model family fails differently, so it catches what Claude misses. It also runs on a subscription you may already pay for, instead of your Anthropic quota.

## Install

```
bash install.sh --with-delegate
```

Then edit `~/.claude/honest-audits/models.json` and set your default models. Nothing is filled in for you, because model names change and depend on your plan.

## Lanes

| Lane | Use |
|---|---|
| review | A second opinion on a plan, a diff or a decision |
| research | Reasoning over material you supply |
| longread | Summarise a big file. The content goes shell to backend and never enters Claude's context |

## Why it is shaped this way

- **Content is injected.** Headless `agy` cannot ask for tool permission, so it auto-denies the tool and returns success with an empty answer. The wrapper puts all content in the prompt, adds a no-tools instruction, and retries once on an empty answer.
- **Read-only is structural.** The agent has no Write or Edit tool. Codex runs in a read-only sandbox in an empty throwaway folder. `--permission edit` is refused.
- **Secrets never leave.** Both wrappers refuse a secret file passed by `--file`, by a symlink, or by a stdin redirect. They use the same path set as the guards. If that set is missing, they fail closed. A pipe is passed through, because the wrapper cannot tell where piped text came from.
- **A person confirms Codex.** An `ask` permission rule covers the wrapper and the plain `codex` command. That is a real prompt, which a model cannot answer for itself. A sentence in a skill saying "ask first" is prose, and prose gets skipped.
- **No failover.** If a backend fails, the wrapper stops and says so. Trying the other one would spend a budget nobody chose.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Answer printed |
| 1 | Usage error or refused. Nothing was sent |
| 2 | Backend failed. Retrying may help |
| 3 | Empty answer. Restructure the call |
| 4 | Codex only: this account cannot use this model |

`--stats` on either wrapper shows its own token spend for the last 7 days. That is a local count, not your remaining quota.

## Tested

The wrappers are tested against fake backends only. The flags are written for the CLIs as they stood when this was built, and both CLIs change. Run one small real call before you rely on it.

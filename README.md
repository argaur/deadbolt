# Honest audits

**Enforcement is scripts, not prose.**

A rule in `CLAUDE.md` is a request. The model usually follows it, until a long session or a tired prompt, and then it doesn't. You find out afterwards.

A hook is different. It runs on every tool call, it does not get tired, and it can say no. This repo is a small set of working hooks for Claude Code, built on one idea: if a rule matters, name the file that stops you. If you can't, you have a hope, not a rule.

It also checks itself, because a guard that broke looks exactly like a guard with nothing to block.

## What you get

| Part | What it does |
|---|---|
| **Guards** | Deny force pushes, skipped git hooks, home or root deletes, printed secrets, reads of secret files, memory-file wipes, and deploys to an unconfirmed target |
| **Canary** | At every session start, sends real forbidden inputs through the guards. Says so if one lets them through |
| **Drift checks** | Compare what is installed with what was installed. Catch retired facts in docs, and rules that claim an executor that is gone |
| **Plan gates** | Pass or fail a plan on tagged steps, stated scope and stated verification |
| **`/delegate`** (optional) | Read-only second opinions from a non-Anthropic model |

Every claim is listed in [docs/ENFORCEMENT.md](docs/ENFORCEMENT.md), and a script checks that table too.

## Prerequisites

| Need | Version |
|---|---|
| OS | Windows 11 with Git Bash, or Linux. See "Tested on" below |
| bash | 4.4 or newer. macOS ships 3.2, so run `brew install bash` and put it first on PATH |
| jq | Any recent version. Required |
| sha256sum or shasum | Required, for the drift check |
| Claude Code | Tested on 2.1.316. Older versions are untested |

The guards need bash features that bash 3.2 lacks, so the installer refuses to run on it. A guard that crashes cannot deny.

## Install

```
git clone <this repo>
cd honest-audits
bash install.sh --dry-run    # see what would change
bash install.sh              # core
```

Add `--with-delegate` for the optional lane in [docs/delegate.md](docs/delegate.md).

The installer:

- puts everything in `~/.claude/honest-audits/`, apart from the model-router skill and, with `--with-delegate`, the `/delegate` command and its agent;
- merges hooks into your `settings.json`, keeps everything else in it, and writes a timestamped backup first;
- never overwrites a file of yours;
- writes a manifest for the drift check;
- runs the canary, and stops with an error if a guard does not deny.

It is safe to run twice. Start a new Claude Code session to load the hooks.

If you would rather wire it by hand, [examples/settings.json](examples/settings.json) is a complete settings file.

To remove it: `bash install.sh --uninstall`. Your own settings and hooks stay.

## Try it

In a new session, ask Claude to run `git push --force`. The guard denies it and says why.

Then see why a canary matters. Run this in your own terminal, not through Claude:

```
cp ~/.claude/honest-audits/hooks/pre-tool-use-guard.sh /tmp/guard.bak
printf '#!/usr/bin/env bash\nexit 0\n' > ~/.claude/honest-audits/hooks/pre-tool-use-guard.sh
bash ~/.claude/honest-audits/hooks/hook-canary.sh
cp /tmp/guard.bak ~/.claude/honest-audits/hooks/pre-tool-use-guard.sh
```

The canary reports `GATE IS FAILING OPEN`.

## What this is not

It is not a sandbox. The guards stop accidents and the common shapes of a bad command. A determined process can get past them, and [docs/guards.md](docs/guards.md) lists the known ways. Keep real secrets out of reach, and keep your own backups.

## Docs

- [The guards, and their known limits](docs/guards.md)
- [Canary and drift checks](docs/drift.md)
- [Plan gates](docs/plan-gates.md)
- [Delegation (optional)](docs/delegate.md)
- [Enforcement table](docs/ENFORCEMENT.md)

## Tests

```
bash tests/guards-test.sh     # adversarial inputs to each guard
bash tests/clean-room.sh      # install into an empty temp HOME, then sabotage it
```

`clean-room.sh` uses a fresh temp HOME, fake env vars and fake backends. It fails if your real `~/.claude/settings.json` changed while it ran. The full run takes several minutes on Windows, because it starts hundreds of bash processes.

**Tested on:** Windows 11 with Git Bash (bash 5.2) and Ubuntu on WSL. macOS is untested.

## License

MIT. See [LICENSE](LICENSE).

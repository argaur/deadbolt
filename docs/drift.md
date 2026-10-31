# Canary and drift checks

A guard that stopped working looks exactly like a guard with nothing to block. A green commit proves the state of a repo, never the state of `~/.claude`. These checks look at what is really installed.

## hook-canary.sh

Runs at every session start. It is silent when all is well, and prints one JSON message when not. It never blocks a session.

1. Every registered hook script exists and parses. A missing hook of ours is a FAIL. A missing hook of yours is a WARNING, because yours may resolve in ways this cannot see.
2. The three guards are registered at all.
3. Real payloads go through the three guards. A forbidden input must come back denied, and a benign one must pass. A guard that lets the forbidden one through is reported as FAILING OPEN.
4. Installed files match the install manifest.

If `jq` is missing, it says so loudly rather than going quiet.

## canary-heartbeat-check.sh

Silent means green, and a canary that never launched is silent too. It cannot report itself. So it leaves a marker on every run, and this separate hook warns if the marker is missing or over 3 days old.

## verify-install.sh

Compares every installed file with the sha256 manifest written at install time. Run it after anything that touches `~/.claude`. If you edit an installed guard on purpose, re-run `install.sh` to refresh the manifest, or the canary will flag it.

```
bash ~/.claude/honest-audits/scripts/verify-install.sh
```

The manifest sits beside the files it describes, so it catches accidents and stale copies. It does not stop someone who rewrites both.

## stale-doc-check.sh

A sweep of old facts is a one-time act, and nobody re-greps a doc they believe is correct. This turns the sweep into a check. Copy `examples/stale-facts.example` to `.stale-facts` at your repo root and list facts that stopped being true.

```
bash ~/.claude/honest-audits/scripts/stale-doc-check.sh /path/to/repo
```

It checks Markdown files only. It is a tool you run or wire into CI. Nothing runs it for you.

## enforcement-check.sh

Reads `docs/ENFORCEMENT.md` and fails if a claimed executor is missing or empty. It cannot prove a guard works, the tests do that. It catches a guard deleted or renamed while the document keeps claiming it.

Use it for your own rules too. Point it at a repo that holds a `docs/ENFORCEMENT.md`.

## model-roster-check.sh

Part of the optional delegation lane. Once every 30 days it compares the models `agy` can see with `models.json`, and asks you to reconcile them. It never updates its own stamp, because the check is done when a person has looked, not when a script exits.

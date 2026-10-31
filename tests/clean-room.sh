#!/usr/bin/env bash
# clean-room.sh: install into a fresh, empty HOME and prove the result works.
# Uses fake env vars and fake backends. Touches nothing outside its temp folder, and
# fails if your real ~/.claude/settings.json changed while it ran.
#
# Usage: bash tests/clean-room.sh [--skip-guards]
#   --skip-guards leaves out the long guards-test.sh pass.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_GUARDS=0; [ "${1:-}" = "--skip-guards" ] && SKIP_GUARDS=1

REAL_HOME="$HOME"
REAL_SETTINGS="$REAL_HOME/.claude/settings.json"
REAL_HASH=""; [ -f "$REAL_SETTINGS" ] && REAL_HASH="$(sha256sum "$REAL_SETTINGS")"

ROOM="$(mktemp -d)"
trap 'rm -rf "$ROOM"' EXIT
export HOME="$ROOM/home"
mkdir -p "$HOME"
unset CLAUDE_PROJECT_DIR

# Fake credentials. They must never appear in any output or backend payload.
export API_KEY="FAKE-api-key-not-real"
export GITHUB_TOKEN="FAKE-token-not-real"
export DATABASE_URL="postgres://fake:fake@localhost/fake"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); }
t()   { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$label"; fi; }
tn()  { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok; fi; }

C="$HOME/.claude"; B="$C/honest-audits"; S="$C/settings.json"
CANARY="$B/hooks/hook-canary.sh"
canary_out() { bash "$CANARY" "$S" 2>/dev/null; }
restore() { cp "$ROOM/good/$1" "$B/$1"; }

# ------------------------------------------------------ core install, empty HOME
t "install: core into an empty HOME"        bash "$REPO/install.sh"
t "install: settings.json created"          test -f "$S"
t "install: settings.json is valid JSON"    jq empty "$S"
t "install: manifest written"               test -s "$B/MANIFEST.sha256"
t "install: canary heartbeat written"       test -f "$B/.canary-last-run"
t "install: skill placed"                   test -f "$C/skills/model-router/SKILL.md"
tn "install: delegate lane NOT in core"     test -e "$B/scripts/codex-delegate.sh"
tn "install: /delegate NOT in core"         test -e "$C/commands/delegate.md"
t "verify-install: clean"                   bash "$B/scripts/verify-install.sh"
t "canary: silent when green"               test -z "$(canary_out)"
EXPECT=$(jq '[.hooks[][].hooks[].command] | length' "$REPO/examples/settings.json" | tr -d '\r')
GOT=$(jq '[.hooks[][].hooks[].command] | length' "$S" | tr -d '\r')
t "install: every example hook registered ($EXPECT)" test "$EXPECT" = "$GOT"

# ------------------------------------------------------------ idempotent re-run
t "install: re-run works"                   bash "$REPO/install.sh"
GOT2=$(jq '[.hooks[][].hooks[].command] | length' "$S" | tr -d '\r')
t "install: re-run adds no duplicate hooks" test "$GOT" = "$GOT2"

# -------------------------------------------------------- dry run changes nothing
BEFORE=$(sha256sum "$S")
t "install: --dry-run works"                bash "$REPO/install.sh" --dry-run --with-delegate
t "install: --dry-run left settings alone"  test "$BEFORE" = "$(sha256sum "$S")"
tn "install: --dry-run left delegate out"   test -e "$B/scripts/codex-delegate.sh"

# ------------------------------------------------- real guards, installed copies
if [ "$SKIP_GUARDS" = "0" ]; then
  if HOOKS="$B/hooks" bash "$REPO/tests/guards-test.sh" > "$ROOM/guards.out" 2>&1; then
    ok
  else
    bad "guards-test against installed hooks"
  fi
  tail -n 12 "$ROOM/guards.out" | cut -c1-120
fi

# ---------------------------------------------------- sabotage: the canary must shout
mkdir -p "$ROOM/good/hooks" "$ROOM/good/scripts"
cp "$B"/hooks/*.sh "$ROOM/good/hooks/"
cp "$B"/scripts/*.sh "$ROOM/good/scripts/"

printf '#!/usr/bin/env bash\nexit 0\n' > "$B/hooks/pre-tool-use-guard.sh"
OUT="$(canary_out)"
case "$OUT" in *"FAILING OPEN"*) ok ;; *) bad "canary: stub pre-tool guard not reported as failing open" ;; esac
t "canary: output is one valid JSON object" jq -e '.systemMessage' <<< "$OUT"
restore hooks/pre-tool-use-guard.sh

printf '#!/usr/bin/env bash\nexit 0\n' > "$B/hooks/deploy-preflight-guard.sh"
case "$(canary_out)" in *"FAILING OPEN"*) ok ;; *) bad "canary: stub deploy guard not caught" ;; esac
restore hooks/deploy-preflight-guard.sh

printf '#!/usr/bin/env bash\nexit 0\n' > "$B/hooks/file-io-guard.sh"
case "$(canary_out)" in *"FAILING OPEN"*) ok ;; *) bad "canary: stub file-io guard not caught" ;; esac
restore hooks/file-io-guard.sh

printf 'if then\n' > "$B/hooks/plan-state-check.sh"
case "$(canary_out)" in *"syntax error"*) ok ;; *) bad "canary: syntax error not caught" ;; esac
restore hooks/plan-state-check.sh

rm "$B/hooks/plan-state-check.sh"
case "$(canary_out)" in *"does not exist"*) ok ;; *) bad "canary: missing hook not caught" ;; esac
restore hooks/plan-state-check.sh

printf '\n# harmless looking edit\n' >> "$B/hooks/ensure-jq.sh"
case "$(canary_out)" in *"differ from the install manifest"*) ok ;; *) bad "canary: drift not caught" ;; esac
tn "verify-install: reports drift"          bash "$B/scripts/verify-install.sh"
restore hooks/ensure-jq.sh
t "verify-install: clean after restore"     bash "$B/scripts/verify-install.sh"

cp "$S" "$ROOM/settings.good"
jq 'del(.hooks.PreToolUse)' "$ROOM/settings.good" | tr -d '\r' > "$S"
case "$(canary_out)" in *"not registered"*) ok ;; *) bad "canary: unregistered guard not caught" ;; esac
printf 'not json' > "$S"
case "$(canary_out)" in *"not valid JSON"*) ok ;; *) bad "canary: broken settings not caught" ;; esac
rm "$S"
case "$(canary_out)" in *"not found"*) ok ;; *) bad "canary: missing settings not caught" ;; esac
cp "$ROOM/settings.good" "$S"

mv "$B/MANIFEST.sha256" "$ROOM/m"
case "$(canary_out)" in *"could not be checked"*) ok ;; *) bad "canary: missing manifest not reported" ;; esac
mv "$ROOM/m" "$B/MANIFEST.sha256"

# A canary with no jq must shout, not go quiet. Needs a PATH that has coreutils but no
# jq: /usr/bin where jq lives elsewhere, otherwise a folder of symlinks.
if [ -x /usr/bin/jq ]; then
  NOJQ="$ROOM/nojq"; mkdir -p "$NOJQ"
  for tool in dirname mkdir tr sed grep date mktemp rm; do ln -s "$(command -v "$tool")" "$NOJQ/$tool"; done
else
  NOJQ=/usr/bin
fi
OUT="$(PATH="$NOJQ" "$BASH" "$CANARY" "$S" 2>/dev/null)"
case "$OUT" in *"jq is not on PATH"*) ok ;; *) bad "canary: missing jq not reported ($OUT)" ;; esac

# ---------------------------------------------------------------- heartbeat
HB="$B/hooks/canary-heartbeat-check.sh"
t "heartbeat: silent when fresh"            test -z "$(bash "$HB")"
touch -d '10 days ago' "$B/.canary-last-run"
case "$(bash "$HB")" in *"days old"*) ok ;; *) bad "heartbeat: stale not reported" ;; esac
rm "$B/.canary-last-run"
case "$(bash "$HB")" in *"never run"*) ok ;; *) bad "heartbeat: missing not reported" ;; esac
canary_out >/dev/null

# ---------------------------------------------------------------- plan state
PR="$ROOM/project"; mkdir -p "$PR/plans"
( cd "$PR" && git init -q . )
PS="$B/hooks/plan-state-check.sh"
case "$(cd "$PR" && bash "$PS")" in *"NO PLAN STATE"*) ok ;; *) bad "plan-state: missing state not nudged" ;; esac
printf '**Current phase:** 4 Build\n' > "$PR/CLAUDE.md"
case "$(cd "$PR" && bash "$PS")" in *"Current phase: 4 Build"*) ok ;; *) bad "plan-state: phase not read" ;; esac
t "plan-state: silent outside a project"    test -z "$(cd "$ROOM" && mkdir -p empty && cd empty && bash "$PS")"

# ---------------------------------------------------------------- plan gate
PG="$B/scripts/plan-gate.sh"
GOODPLAN="$PR/plans/good.md"
cat > "$GOODPLAN" <<'EOF'
# Plan
- [ ] **Step 1** `[model: sonnet, effort: low]`
- [ ] **Step 2** `[model: opus, effort: high]`
Decision: [H] the cache holds, accepted-risk: lead-dev
## Out of scope
Nothing else.
## Verify
Run the tests.
EOF
t "plan-gate: good plan passes"             bash "$PG" "$GOODPLAN"
sed 's/ `\[model: sonnet, effort: low\]`//' "$GOODPLAN" > "$PR/plans/untagged.md"
tn "plan-gate: untagged step fails"         bash "$PG" "$PR/plans/untagged.md"
grep -v -i 'out of scope' "$GOODPLAN" > "$PR/plans/noscope.md"
tn "plan-gate: no scope heading fails"      bash "$PG" "$PR/plans/noscope.md"
grep -v '^## Verify' "$GOODPLAN" > "$PR/plans/noverify.md"
tn "plan-gate: no verify heading fails"     bash "$PG" "$PR/plans/noverify.md"
sed 's/, accepted-risk: lead-dev//' "$GOODPLAN" > "$PR/plans/hyp.md"
tn "plan-gate: unowned hypothesis fails"    bash "$PG" "$PR/plans/hyp.md"
printf '# Plan\n## Out of scope\n## Verify\n' > "$PR/plans/nosteps.md"
tn "plan-gate: no steps fails"              bash "$PG" "$PR/plans/nosteps.md"
RC=0; bash "$PG" "$PR/plans/missing.md" >/dev/null 2>&1 || RC=$?
t "plan-gate: missing file is refused (2)"  test "$RC" = "2"

# ---------------------------------------------------------------- plan nudge
NG="$B/hooks/plan-finalized-nudge.sh"
nudge() { jq -cn --arg t "$1" --arg p "$2" '{tool_name:$t,tool_input:{file_path:$p}}' | tr -d '\r' | bash "$NG"; }
case "$(nudge Write "$GOODPLAN")" in *"READY"*) ok ;; *) bad "nudge: gate result missing for a good plan" ;; esac
case "$(nudge Write "$PR/plans/untagged.md")" in *"NOT READY"*) ok ;; *) bad "nudge: failure not carried" ;; esac
case "$(nudge ExitPlanMode "")" in *"finalized"*) ok ;; *) bad "nudge: ExitPlanMode not caught" ;; esac
t "nudge: silent on other writes"           test -z "$(nudge Write "$PR/src/app.md")"

# ---------------------------------------------------------------- enforcement check
t "enforcement-check: repo table is clean"  bash "$REPO/scripts/enforcement-check.sh" "$REPO"
ET="$ROOM/table"; mkdir -p "$ET/docs"
cat > "$ET/docs/ENFORCEMENT.md" <<'EOF'
## Enforced
| ID | Rule | Executor |
|---|---|---|
| E1 | gone | `scripts/nope.sh` |
EOF
RC=0; bash "$REPO/scripts/enforcement-check.sh" "$ET" >/dev/null 2>&1 || RC=$?
t "enforcement-check: missing executor exits 1" test "$RC" = "1"
sed -i 's/`scripts\/nope.sh`/some prose/' "$ET/docs/ENFORCEMENT.md"
RC=0; bash "$REPO/scripts/enforcement-check.sh" "$ET" >/dev/null 2>&1 || RC=$?
t "enforcement-check: prose executor exits 2"   test "$RC" = "2"

# ---------------------------------------------------------------- stale docs
SD="$ROOM/stale"; mkdir -p "$SD/docs/archive"
printf 'exclude archive\nPhases 0-6 ::: there are eight phases\n' > "$SD/.stale-facts"
printf 'all fine\n' > "$SD/docs/a.md"
printf 'Phases 0-6 once\n' > "$SD/docs/archive/old.md"
t "stale-doc: clean, and history is skipped" bash "$REPO/scripts/stale-doc-check.sh" "$SD"
printf 'Phases 0-6 again\n' > "$SD/docs/b.md"
RC=0; bash "$REPO/scripts/stale-doc-check.sh" "$SD" >/dev/null 2>&1 || RC=$?
t "stale-doc: retired fact exits 1"         test "$RC" = "1"
printf 'no separator\n' > "$SD/.stale-facts"
RC=0; bash "$REPO/scripts/stale-doc-check.sh" "$SD" >/dev/null 2>&1 || RC=$?
t "stale-doc: bad rule exits 2"             test "$RC" = "2"

# ------------------------------------------------------- existing settings are kept
rm -rf "$HOME"; mkdir -p "$C"
cat > "$S" <<'EOF'
{ "model": "my-model", "env": {"FOO": "1"},
  "permissions": {"allow": ["Bash(ls:*)"], "ask": ["Bash(rm:*)"]},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine.sh"}]}]} }
EOF
printf 'my own skill\n' > "$ROOM/mine.md"
mkdir -p "$C/commands" && cp "$ROOM/mine.md" "$C/commands/delegate.md"
t "install: into existing settings, with delegate" bash "$REPO/install.sh" --with-delegate
t "merge: model kept"          test "$(jq -r .model "$S" | tr -d '\r')" = "my-model"
t "merge: env kept"            test "$(jq -r .env.FOO "$S" | tr -d '\r')" = "1"
t "merge: allow rule kept"     test "$(jq -r '.permissions.allow[0]' "$S" | tr -d '\r')" = "Bash(ls:*)"
t "merge: ask rule kept"       jq -e '.permissions.ask | index("Bash(rm:*)")' "$S"
t "merge: your hook kept"      jq -e '[.hooks.PreToolUse[].hooks[].command] | index("echo mine.sh")' "$S"
t "merge: guard added"         jq -e '[.hooks.PreToolUse[].hooks[].command] | map(contains("pre-tool-use-guard")) | any' "$S"
t "merge: codex ask rule added" jq -e '.permissions.ask | index("Bash(*codex-delegate.sh*)")' "$S"
t "install: settings backup written" compgen -G "$S.bak-honest-audits-*"
t "install: your delegate.md was not overwritten" cmp "$ROOM/mine.md" "$C/commands/delegate.md"
t "install: models.json placed" test -f "$B/models.json"

printf 'not json' > "$ROOM/s.bad"; cp "$S" "$ROOM/s.keep"; cp "$ROOM/s.bad" "$S"
tn "install: refuses invalid settings.json" bash "$REPO/install.sh"
t "install: left the invalid file untouched" cmp "$ROOM/s.bad" "$S"
cp "$ROOM/s.keep" "$S"

# ------------------------------------------------- delegate wrappers, fake backends
BIN="$ROOM/bin"; mkdir -p "$BIN"
SENT="$ROOM/sent.txt"
cat > "$BIN/agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SENT"
case "\${FAKE_AGY:-ok}" in
  empty) echo '{"status":"SUCCESS","response":""}' ;;
  fail)  echo boom >&2; exit 7 ;;
  *)     echo '{"status":"SUCCESS","response":"fake answer","usage":{"input_tokens":10,"output_tokens":2}}' ;;
esac
EOF
cat > "$BIN/codex" <<EOF
#!/usr/bin/env bash
cat >> "$SENT"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
case "\${FAKE_CODEX:-ok}" in
  empty)  echo '{"type":"turn.completed"}' ;;
  denied) echo 'error: model_not_found' ; exit 1 ;;
  quota)  echo 'error: model_not_found, rate limit reached' ; exit 1 ;;
  *)      printf 'fake answer\n' > "\$out"
          echo '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":1}}' ;;
esac
EOF
chmod +x "$BIN/agy" "$BIN/codex"
export PATH="$BIN:$PATH"

AG="$B/scripts/agy-delegate.sh"; CD="$B/scripts/codex-delegate.sh"
WS="$ROOM/ws"; mkdir -p "$WS/.ssh"
printf 'API_KEY=FAKE-file-secret-not-real\n' > "$WS/.env"
printf 'FAKE-KEY\n' > "$WS/.ssh/id_ed25519"
printf 'plain content for review\n' > "$WS/notes.txt"

RC=0; bash "$AG" --type review "x" >/dev/null 2>&1 || RC=$?
t "agy: unset default model is refused"     test "$RC" = "1"
jq '.providers.google.default="fake-model" | .providers.google.longread_default="fake-model" | .providers.codex.default="fake-model"' \
  "$B/models.json" | tr -d '\r' > "$ROOM/m.json" && cp "$ROOM/m.json" "$B/models.json"

for W in "$AG" "$CD"; do
  N="${W##*/}"
  : > "$SENT"
  t "$N: plain file is sent"                bash "$W" --type review --file "$WS/notes.txt" "review this"
  t "$N: payload carried the file"          grep -q 'plain content for review' "$SENT"
  : > "$SENT"
  RC=0; bash "$W" --type review --file "$WS/.env" "x" >/dev/null 2>&1 || RC=$?
  t "$N: .env refused"                      test "$RC" = "1"
  RC=0; bash "$W" --type review --file "$WS/.ssh/id_ed25519" "x" >/dev/null 2>&1 || RC=$?
  t "$N: ssh key refused"                   test "$RC" = "1"
  RC=0; bash "$W" --type review --stdin "x" < "$WS/.env" >/dev/null 2>&1 || RC=$?
  t "$N: stdin redirect of .env refused"    test "$RC" = "1"
  ln -s "$WS/.env" "$WS/innocent.txt" 2>/dev/null
  if [ -L "$WS/innocent.txt" ]; then
    RC=0; bash "$W" --type review --file "$WS/innocent.txt" "x" >/dev/null 2>&1 || RC=$?
    t "$N: symlink to .env refused"         test "$RC" = "1"
  fi
  rm -f "$WS/innocent.txt"
  tn "$N: secret never reached the backend" grep -q 'FAKE-file-secret' "$SENT"
  RC=0; bash "$W" "no type" >/dev/null 2>&1 || RC=$?
  t "$N: missing --type is a usage error"   test "$RC" = "1"
  RC=0; bash "$W" --type review --bogus "x" >/dev/null 2>&1 || RC=$?
  t "$N: unknown flag is a usage error"     test "$RC" = "1"
  t "$N: --stats works"                     bash "$W" --stats
done

RC=0; FAKE_AGY=empty bash "$AG" --type review "x" >/dev/null 2>&1 || RC=$?
t "agy: empty answer twice exits 3"         test "$RC" = "3"
RC=0; FAKE_AGY=fail bash "$AG" --type review "x" >/dev/null 2>&1 || RC=$?
t "agy: backend failure exits 2"            test "$RC" = "2"
RC=0; bash "$CD" --type review --permission edit "x" >/dev/null 2>&1 || RC=$?
t "codex: --permission edit refused"        test "$RC" = "1"
RC=0; FAKE_CODEX=empty bash "$CD" --type review "x" >/dev/null 2>&1 || RC=$?
t "codex: empty answer exits 3"             test "$RC" = "3"
RC=0; FAKE_CODEX=denied bash "$CD" --type review "x" >/dev/null 2>&1 || RC=$?
t "codex: refused model exits 4"            test "$RC" = "4"
RC=0; FAKE_CODEX=quota bash "$CD" --type review "x" >/dev/null 2>&1 || RC=$?
t "codex: quota error stays exit 2"         test "$RC" = "2"

# ---------------------------------------------------------------- roster check
RK="$B/hooks/model-roster-check.sh"
case "$(bash "$RK")" in *"CHECK DUE"*) ok ;; *) bad "roster: first run not due" ;; esac
touch "$B/.model-roster-last-check"
t "roster: silent when the stamp is fresh"  test -z "$(bash "$RK")"
touch -d '40 days ago' "$B/.model-roster-last-check"
case "$(bash "$RK")" in *"CHECK DUE"*) ok ;; *) bad "roster: stale stamp not due" ;; esac
mv "$B/models.json" "$ROOM/m2"
case "$(bash "$RK")" in *"MISSING"*) ok ;; *) bad "roster: missing roster not reported" ;; esac
mv "$ROOM/m2" "$B/models.json"

# ---------------------------------------------------------------- uninstall
t "uninstall: runs"                         bash "$REPO/install.sh" --uninstall
tn "uninstall: our folder is gone"          test -e "$B"
tn "uninstall: skill is gone"               test -e "$C/skills/model-router/SKILL.md"
t "uninstall: your delegate.md survived"    cmp "$ROOM/mine.md" "$C/commands/delegate.md"
t "uninstall: settings still valid"         jq empty "$S"
t "uninstall: model kept"                   test "$(jq -r .model "$S" | tr -d '\r')" = "my-model"
t "uninstall: your ask rule kept"           jq -e '.permissions.ask | index("Bash(rm:*)")' "$S"
t "uninstall: your hook kept"               jq -e '[.hooks.PreToolUse[].hooks[].command] | index("echo mine.sh")' "$S"
if jq -e '[.. | strings | select(contains("honest-audits/"))] | length == 0' "$S" >/dev/null; then ok; else bad "uninstall: our hooks remain"; fi
if jq -e '.permissions.ask | index("Bash(codex *)") | not' "$S" >/dev/null; then ok; else bad "uninstall: codex ask rule remains"; fi

# ------------------------------------------------------- no fake secret in any file
HITS=$(grep -rl 'FAKE-api-key-not-real\|FAKE-token-not-real' "$C" 2>/dev/null | wc -l | tr -d ' ')
t "no fake env value was written to disk"   test "$HITS" = "0"

# ---------------------------------------------------- the real HOME was not touched
export HOME="$REAL_HOME"
if [ -n "$REAL_HASH" ]; then
  t "real ~/.claude/settings.json unchanged" test "$REAL_HASH" = "$(sha256sum "$REAL_SETTINGS")"
fi

echo "clean-room: $PASS passed, $FAIL failed"
for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "  FAIL $f"; done
[ "$FAIL" = "0" ]

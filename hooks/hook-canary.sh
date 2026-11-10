#!/usr/bin/env bash
# hook-canary.sh: SessionStart smoke test for the whole enforcement layer.
#
# A guard that stopped working looks exactly like a guard with nothing to block.
# So at every session start this checks the installed layer, not the repo:
#   1. every hook registered in settings.json exists and parses;
#   2. the three guards are registered at all;
#   3. real payloads go through the three guards: a forbidden one must be denied,
#      a benign one must pass. This is the check that catches a broken guard;
#   4. the installed files still match the manifest written at install time.
#
# Contract: always exits 0, because a failing SessionStart hook can disrupt the
# session. Silent when green. On any problem it prints one JSON object.
#
# Usage: bash hook-canary.sh [settings-file]   default ~/.claude/settings.json

source "$(dirname "${BASH_SOURCE[0]}")/ensure-jq.sh" 2>/dev/null || true

SETTINGS="${1:-$HOME/.claude/settings.json}"
BASE="$HOME/.claude/deadbolt"
HEARTBEAT="$BASE/.canary-last-run"
VERIFY="$(dirname "${BASH_SOURCE[0]}")/../scripts/verify-install.sh"

PROBLEMS=()
add() { PROBLEMS+=("$1"); }

json_escape() {
  local s
  s=$(printf '%s' "$1" | tr -d '\r\000-\010\013\014\016-\037')
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# report: write the heartbeat first, on every path. canary-heartbeat-check.sh reads
# it, because a canary that never launched is silent too, and silent means green.
report() {
  trap - EXIT
  [ -n "${TMPD:-}" ] && [ -d "$TMPD" ] && rm -rf "$TMPD"
  mkdir -p "$BASE" >/dev/null 2>&1
  : > "$HEARTBEAT" 2>/dev/null || true
  [ ${#PROBLEMS[@]} -eq 0 ] && exit 0

  local msg="HOOK CANARY: warnings from the enforcement layer." p esc
  printf '%s\n' "${PROBLEMS[@]}" | grep -q '^FAIL' && \
    msg="HOOK CANARY: the enforcement layer is NOT healthy."
  msg="$msg"$'\n'"settings: $SETTINGS"
  for p in "${PROBLEMS[@]}"; do msg="$msg"$'\n'"  - $p"; done
  msg="$msg"$'\n'"Fix this before trusting any guard."
  esc=$(json_escape "$msg")
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc" "$esc"
  exit 0
}
trap 'report' EXIT

# A canary that goes quiet when its own dependency vanishes is the failure it hunts.
if ! command -v jq >/dev/null 2>&1; then
  add "FAIL: jq is not on PATH, so NO hook was verified. The layer is unverified, not healthy."
  report
fi
if [ ! -f "$SETTINGS" ]; then
  add "FAIL: settings file not found: $SETTINGS"
  report
fi

# norm_path: expand ~ and $HOME, flip backslashes, map C:/ to /c/. Sets NP.
NP=""
norm_path() {
  local p="$1" d
  p="${p//\\//}"
  p="${p//\$\{HOME\}/$HOME}"; p="${p//\$HOME/$HOME}"
  case "$p" in "~"|"~/"*) p="$HOME${p#\~}" ;; esac
  if [ ! -e "$p" ]; then
    case "$p" in
      [A-Za-z]:/*) d="${p:0:1}"; p="/${d,}${p:2}" ;;
    esac
  fi
  NP="$p"
}

# extract_path: the script path out of a hook command line. Sets EP.
EP=""
extract_path() {
  local cmd="$1" p=""
  if   [[ $cmd =~ \"([^\"]*\.(sh|ps1))\" ]]; then p="${BASH_REMATCH[1]}"
  elif [[ $cmd =~ \'([^\']*\.(sh|ps1))\' ]]; then p="${BASH_REMATCH[1]}"
  elif [[ $cmd =~ ([^[:space:]\"\']+\.(sh|ps1)) ]]; then p="${BASH_REMATCH[1]}"
  fi
  EP="$p"
}

HOOK_LINES=$(jq -r '
  (.hooks // {}) | to_entries[] | .key as $event
  | (.value // [])[] | (.hooks // [])[]
  | select((.type // "command") == "command")
  | [$event, (.command // "")] | join("\u0001")' "$SETTINGS" 2>/dev/null | tr -d '\r') || true

if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  add "FAIL: settings file is not valid JSON: $SETTINGS"
  report
fi
if [ -z "$HOOK_LINES" ]; then
  add "FAIL: no hooks are registered in $SETTINGS, so nothing is enforced."
  report
fi

PRE=""; DEPLOY=""; FILEIO=""
SH_PATHS=(); SH_EVENTS=()
while IFS=$'\001' read -r EVENT CMD; do
  [ -n "$CMD" ] || continue
  extract_path "$CMD"
  [ -n "$EP" ] || continue        # not a script path; another tool's hook
  case "$EP" in *'$'*) [[ $EP != *HOME* ]] && continue ;; esac   # a variable we cannot resolve
  norm_path "$EP"; P="$NP"
  if [ ! -f "$P" ]; then
    # Your own hooks may resolve in ways this cannot see. Only ours are a FAIL.
    case "$P" in
      */deadbolt/*) add "FAIL: [$EVENT] hook script does not exist: $P" ;;
      *) add "WARNING: [$EVENT] could not find this hook's script: $P" ;;
    esac
    continue
  fi
  case "$P" in *.sh) SH_PATHS+=("$P"); SH_EVENTS+=("$EVENT") ;; esac
  case "${P##*/}" in
    pre-tool-use-guard.sh)     PRE="$P" ;;
    deploy-preflight-guard.sh) DEPLOY="$P" ;;
    file-io-guard.sh)          FILEIO="$P" ;;
  esac
done <<< "$HOOK_LINES"

[ -n "$PRE" ]    || add "FAIL: pre-tool-use-guard.sh is not registered. Forbidden commands are UNBLOCKED."
[ -n "$DEPLOY" ] || add "FAIL: deploy-preflight-guard.sh is not registered. Deploys are UNCHECKED."
[ -n "$FILEIO" ] || add "FAIL: file-io-guard.sh is not registered. Secret files are READABLE."

# Working folder. It holds a CLAUDE.md with no Deploy target line, so the deploy
# guard must deny inside it, wherever the temp folder happens to sit.
TMPD=$(mktemp -d 2>/dev/null)
if [ ! -d "$TMPD" ]; then
  add "FAIL: could not create a temp folder, so no guard was probed."
  report
fi
printf '# canary fixture\n' > "$TMPD/CLAUDE.md"

unset CLAUDE_PROJECT_DIR
RUN=(); command -v timeout >/dev/null 2>&1 && RUN=(timeout 5)

# Forbidden strings are built from fragments, so a model reading this file through
# a guard-protected shell is never blocked by the file's own text.
_P="pu"; _P="${_P}sh"; _F="--fo"; _F="${_F}rce"
_V="ver"; _V="${_V}cel"; _D="--pr"; _D="${_D}od"
_E=".e"; _E="${_E}nv"

payload() {   # payload <tool> <json-key> <value>
  jq -cn --arg t "$1" --arg k "$2" --arg v "$3" \
    '{session_id:"canary",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{($k):$v}}' | tr -d '\r'
}

N=0; LABELS=(); GATES=(); KINDS=()
probe() {   # probe <label> <gate> <deny|allow> <payload>
  local n=$N
  N=$((N+1))
  LABELS[n]="$1"; GATES[n]="$2"; KINDS[n]="$3"
  printf '%s' "$4" > "$TMPD/in.$n"
  ( "${RUN[@]}" bash "$2" < "$TMPD/in.$n" > "$TMPD/out.$n" 2>/dev/null; printf '%s' $? > "$TMPD/rc.$n" ) &
}

if [ -n "$PRE" ]; then
  probe "pre-tool-use guard" "$PRE" deny  "$(payload Bash command "git $_P origin main $_F")"
  probe "pre-tool-use guard" "$PRE" allow "$(payload Bash command "ls -la")"
fi
if [ -n "$DEPLOY" ]; then
  probe "deploy guard" "$DEPLOY" deny  "$(payload Bash command "cd $TMPD && $_V $_D")"
  probe "deploy guard" "$DEPLOY" allow "$(payload Bash command "ls -la")"
fi
if [ -n "$FILEIO" ]; then
  probe "file-io guard" "$FILEIO" deny  "$(payload Read file_path "$TMPD/$_E")"
  probe "file-io guard" "$FILEIO" allow "$(payload Read file_path "$TMPD/CLAUDE.md")"
fi

for i in "${!SH_PATHS[@]}"; do
  ( bash -n "${SH_PATHS[$i]}" 2>"$TMPD/syn.$i.err"; printf '%s' $? > "$TMPD/syn.$i.rc" ) &
done
if [ -f "$VERIFY" ]; then
  ( bash "$VERIFY" --quiet > "$TMPD/verify.out" 2>&1; printf '%s' $? > "$TMPD/verify.rc" ) &
fi
wait

for i in "${!SH_PATHS[@]}"; do
  rc=1; [ -f "$TMPD/syn.$i.rc" ] && read -r rc < "$TMPD/syn.$i.rc"
  if [ "$rc" != "0" ]; then
    add "FAIL: [${SH_EVENTS[$i]}] ${SH_PATHS[$i]} has a bash syntax error: $(<"$TMPD/syn.$i.err")"
  fi
done

for ((n=0; n<N; n++)); do
  out=""; [ -f "$TMPD/out.$n" ] && out=$(<"$TMPD/out.$n")
  rc=1;   [ -f "$TMPD/rc.$n" ]  && read -r rc < "$TMPD/rc.$n"
  if [ "${KINDS[$n]}" = "deny" ]; then
    # jq, not a substring: the difference between denied and deny-shaped text.
    if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
      continue
    fi
    add "FAIL, GATE IS FAILING OPEN: ${LABELS[$n]} (${GATES[$n]}) did NOT deny a known-forbidden input. Output: ${out:-<empty>}"
  elif [ "$rc" != "0" ] || [ -n "$out" ]; then
    add "FAIL: ${LABELS[$n]} (${GATES[$n]}) did not pass a benign input (exit $rc). It is blocking real work. Output: ${out:-<empty>}"
  fi
done

if [ ! -f "$VERIFY" ]; then
  add "FAIL: verify-install.sh is missing: $VERIFY"
else
  vrc=1; [ -f "$TMPD/verify.rc" ] && read -r vrc < "$TMPD/verify.rc"
  case "$vrc" in
    0) : ;;
    1) add "FAIL: installed files differ from the install manifest. Run: bash \"$VERIFY\"" ;;
    *) add "WARNING: the install manifest could not be checked (exit $vrc). Run: bash \"$VERIFY\"" ;;
  esac
fi

report

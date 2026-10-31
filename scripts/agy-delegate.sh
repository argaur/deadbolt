#!/usr/bin/env bash
# agy-delegate.sh: read-only delegation to Google Antigravity (`agy`). OPTIONAL.
#
# Headless agy cannot ask for tool permission. It auto-denies the tool and returns
# status SUCCESS with an EMPTY answer, a silent failure. Which tool the model reaches
# for varies from run to run. So agy never touches the filesystem: this script builds
# the payload in the shell and injects file contents into the prompt.
#   1. Read-only is structural: agy has no filesystem access to abuse.
#   2. File contents go shell to agy and never enter Claude's own context.
#   3. No turns are spent on denied tool calls.
#
# Usage:
#   agy-delegate.sh --type research|review|longread [options] "prompt"
#   agy-delegate.sh --type review --file diff.txt "Critique this diff"
#   cat big.log | agy-delegate.sh --type longread --stdin "Summarise the errors"
#
# Options:
#   --type   research | review | longread   (required, selects the default model)
#   --file   PATH   include this file's contents (repeatable)
#   --stdin         also read content from stdin
#   --model  NAME   override the model. Defaults come from models.json
#   --effort low|medium|high
#   --raw           print the full JSON, not just the answer
#   --stats         this wrapper's own token spend, last 7 days
#
# Exit: 0 ok, 1 usage error or refused, 2 agy failed, 3 empty answer twice

set -euo pipefail

die() { echo "agy-delegate: $*" >&2; exit "${2:-1}"; }

BASE="$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
ROSTER="$BASE/models.json"
LEDGER="${AGY_LEDGER:-$BASE/agy-usage.log}"

TYPE=""; MODEL=""; EFFORT=""; RAW=0; USE_STDIN=0; STATS=0
FILES=(); PROMPT_PARTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)   [[ $# -ge 2 ]] || die "--type needs a value"; TYPE="$2"; shift 2 ;;
    --model)  [[ $# -ge 2 ]] || die "--model needs a value"; MODEL="$2"; shift 2 ;;
    --effort) [[ $# -ge 2 ]] || die "--effort needs a value"; EFFORT="$2"; shift 2 ;;
    --file)   [[ $# -ge 2 ]] || die "--file needs a path"; FILES+=("$2"); shift 2 ;;
    --stdin)  USE_STDIN=1; shift ;;
    --raw)    RAW=1; shift ;;
    --stats)  STATS=1; shift ;;
    -h|--help) awk 'NR>1 { if (/^#/) print; else exit }' "$0"; exit 0 ;;
    -*)       die "unknown option: $1" ;;
    *)        PROMPT_PARTS+=("$1"); shift ;;
  esac
done

if [[ $STATS -eq 1 ]]; then
  [[ -f "$LEDGER" ]] || { echo "No usage recorded yet ($LEDGER does not exist)."; exit 0; }
  CUTOFF="$(date -d '7 days ago' +%s 2>/dev/null || echo 0)"
  awk -F'\t' -v cutoff="$CUTOFF" '
    $1 >= cutoff { n++; i += $3; o += $4; if ($6 == "retried") r++ }
    END {
      printf "agy spend, last 7 days (this wrapper only, not the remaining quota)\n"
      printf "  %d calls, %d in / %d out tokens, %d retried\n", n, i, o, r
      printf "For the real remaining figure, run agy interactively and use /usage.\n"
    }' "$LEDGER"
  exit 0
fi

command -v agy >/dev/null 2>&1 || die "agy is not on PATH. This lane is optional. See docs/delegate.md"
command -v jq  >/dev/null 2>&1 || die "jq is not on PATH"

case "$TYPE" in
  research|review|longread) ;;
  "") die "--type is required (research | review | longread)" ;;
  *)  die "invalid --type '$TYPE' (expected research | review | longread)" ;;
esac

[[ ${#PROMPT_PARTS[@]} -gt 0 ]] || die "no prompt given"
PROMPT="${PROMPT_PARTS[*]}"

if [[ -z "$MODEL" ]]; then
  KEY=default; [[ "$TYPE" == "longread" ]] && KEY=longread_default
  [[ -f "$ROSTER" ]] && MODEL="$(jq -r --arg k "$KEY" '.providers.google[$k] // ""' "$ROSTER" | tr -d '\r')"
  [[ -n "$MODEL" && "$MODEL" != REPLACE* ]] || die "no default model. Set providers.google.$KEY in $ROSTER, or pass --model"
fi

# A secret file never leaves the machine. The set is hooks/secret-paths.sh, found from
# this script's own folder, never through an env var a caller could repoint. No
# library means the check fails closed.
SECRET_LIB="$BASE/hooks/secret-paths.sh"
SECRET_LIB_LOADED=0
is_secret_target() {
  local p
  if [[ $SECRET_LIB_LOADED -eq 0 ]]; then
    [[ -f "$SECRET_LIB" ]] || die "the secret check needs $SECRET_LIB, and it is missing"
    # shellcheck source=/dev/null
    source "$SECRET_LIB" || die "could not load $SECRET_LIB"
    SECRET_LIB_LOADED=1
  fi
  for p in "$1" "$(readlink -f -- "$1" 2>/dev/null || true)"; do
    [[ -n "$p" ]] || continue
    is_secret_path "$p" && return 0
    is_secret_store_dir "$p" && return 0
  done
  return 1
}

for f in "${FILES[@]+"${FILES[@]}"}"; do
  is_secret_target "$f" && die "--file is a secret-bearing file, it is never sent to agy: $f"
done
# `--stdin < .env` is the same read as `--file .env`. A redirect resolves to a real
# file and is judged. A pipe is text the caller built, and it passes.
if [[ "$USE_STDIN" -eq 1 && -f /dev/stdin ]]; then
  STDIN_SRC="$(readlink -f /dev/stdin 2>/dev/null || true)"
  [[ -n "$STDIN_SRC" ]] || die "--stdin is a file whose path could not be resolved, so it cannot be checked"
  is_secret_target "$STDIN_SRC" && die "--stdin is a secret-bearing file, it is never sent to agy: $STDIN_SRC"
fi

PAYLOAD="$PROMPT"
for f in "${FILES[@]+"${FILES[@]}"}"; do
  [[ -f "$f" ]] || die "--file not found: $f"
  [[ -r "$f" ]] || die "--file not readable: $f"
  PAYLOAD="$PAYLOAD

--- BEGIN FILE: $f ---
$(cat -- "$f")
--- END FILE: $f ---"
done

if [[ "$USE_STDIN" -eq 1 ]]; then
  STDIN_CONTENT="$(cat)"
  [[ -n "$STDIN_CONTENT" ]] || die "--stdin given but stdin was empty"
  PAYLOAD="$PAYLOAD

--- BEGIN STDIN ---
$STDIN_CONTENT
--- END STDIN ---"
fi

NO_TOOLS="All material you need is included in this message. Do not read, search, list, open, or execute anything, and do not call any tool: you are running headless with no tool access, and any tool call is auto-denied and silently discards your entire answer. Answer directly from the text below."

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT
HARD_TIMEOUT="${AGY_HARD_TIMEOUT:-360}"

# Sets JSON_LINE, STATUS, RESPONSE. Returns 3 on the empty-answer signature.
run_agy() {
  local rc=0 raw=""
  local -a args=(-p "$1" --mode plan --model "$MODEL" --output-format json
                 --print-timeout "${AGY_PRINT_TIMEOUT:-5m}")
  [[ -n "$EFFORT" ]] && args+=(--effort "$EFFORT")
  if command -v timeout >/dev/null 2>&1; then
    raw="$(timeout "$HARD_TIMEOUT" agy "${args[@]}" 2>"$ERR_FILE")" || rc=$?
  else
    raw="$(agy "${args[@]}" 2>"$ERR_FILE")" || rc=$?
  fi
  [[ $rc -ne 124 ]] || die "agy timed out after ${HARD_TIMEOUT}s" 2
  if [[ $rc -ne 0 ]]; then
    cat "$ERR_FILE" >&2
    die "agy exited $rc" 2
  fi
  JSON_LINE=""
  if [[ -n "${raw//[[:space:]]/}" ]]; then
    JSON_LINE="$(printf '%s' "$raw" | jq -c -s 'map(select(type == "object")) | last // empty' 2>/dev/null | tr -d '\r' || true)"
  fi
  if [[ -z "$JSON_LINE" || "$JSON_LINE" == "null" ]]; then
    cat "$ERR_FILE" >&2
    die "agy produced no parseable JSON on stdout. Raw start: ${raw:0:200}" 2
  fi
  STATUS="$(printf '%s' "$JSON_LINE" | jq -r '.status // "UNKNOWN"' | tr -d '\r')"
  RESPONSE="$(printf '%s' "$JSON_LINE" | jq -r '.response // ""' | tr -d '\r')"
  [[ -n "$RESPONSE" ]] || return 3
  return 0
}

RETRIED=0
if ! run_agy "$NO_TOOLS

$PAYLOAD"; then
  echo "agy-delegate: empty answer (a tool was auto-denied). Retrying once with a blunter instruction." >&2
  RETRIED=1
  if ! run_agy "CRITICAL: your previous attempt returned nothing because you tried to use a tool. You have NO tools. Reply using ONLY the text in this message.

$NO_TOOLS

$PAYLOAD"; then
    echo "agy-delegate: status=$STATUS with an EMPTY answer, twice." >&2
    echo "agy-delegate: pass every input with --file or --stdin, and ask only about that text." >&2
    exit 3
  fi
fi

[[ "$STATUS" == "SUCCESS" ]] || echo "agy-delegate: warning, status=$STATUS (the answer may be partial)" >&2

if [[ $RAW -eq 1 ]]; then printf '%s\n' "$JSON_LINE"; else printf '%s\n' "$RESPONSE"; fi

# Ledger: best effort, a logging problem never fails a call that already worked.
{
  IN_TOK="$(printf '%s' "$JSON_LINE" | jq -r '.usage.input_tokens // 0' | tr -d '\r')"
  OUT_TOK="$(printf '%s' "$JSON_LINE" | jq -r '.usage.output_tokens // 0' | tr -d '\r')"
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$MODEL" "$IN_TOK" "$OUT_TOK" "$TYPE" \
    "$([[ $RETRIED -eq 1 ]] && echo retried || echo ok)" >> "$LEDGER"
} 2>/dev/null || true

echo "[agy ${IN_TOK:-0} in / ${OUT_TOK:-0} out tokens, model $MODEL]" >&2

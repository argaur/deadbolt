#!/usr/bin/env bash
# codex-delegate.sh: read-only delegation to the OpenAI Codex CLI. OPTIONAL.
#
# Review only. There is no write path:
#   - it runs `codex exec --sandbox read-only` in an empty throwaway folder;
#   - all content is injected, so a request to read anything has nothing to find;
#   - `--permission edit` is refused.
#
# Consent is a permission prompt, not a promise. examples/settings.delegate.json adds
# an `ask` rule on this script, so a human confirms every call. A model cannot
# approve its own permission prompt, which is why this is an `ask` rule and not an
# instruction in a skill.
#
# Usage:
#   codex-delegate.sh --type research|review|longread [options] "prompt"
#   codex-delegate.sh --type review --file diff.txt "Critique this diff"
#
# Options:
#   --type   research | review | longread   (required)
#   --file   PATH   include this file's contents (repeatable)
#   --stdin         also read content from stdin
#   --model  NAME   override the model. The default comes from models.json
#   --effort low|medium|high
#   --stats         this wrapper's own token spend, last 7 days
#
# Exit: 0 ok, 1 usage error or refused, 2 codex failed, 3 empty answer,
#       4 model refused for this account, not retryable

set -euo pipefail

die() { echo "codex-delegate: $*" >&2; exit "${2:-1}"; }

BASE="$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
ROSTER="$BASE/models.json"
LEDGER="${CODEX_LEDGER:-$BASE/codex-usage.log}"

TYPE=""; MODEL=""; EFFORT=""; USE_STDIN=0; STATS=0; PERMISSION=review
FILES=(); PROMPT_PARTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)   [[ $# -ge 2 ]] || die "--type needs a value"; TYPE="$2"; shift 2 ;;
    --model)  [[ $# -ge 2 ]] || die "--model needs a value"; MODEL="$2"; shift 2 ;;
    --effort) [[ $# -ge 2 ]] || die "--effort needs a value"; EFFORT="$2"; shift 2 ;;
    --file)   [[ $# -ge 2 ]] || die "--file needs a path"; FILES+=("$2"); shift 2 ;;
    --permission) [[ $# -ge 2 ]] || die "--permission needs a value"; PERMISSION="$2"; shift 2 ;;
    --stdin)  USE_STDIN=1; shift ;;
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
    $1 >= cutoff { n++; i += $3; o += $4 }
    END { printf "codex spend, last 7 days (this wrapper only, not the remaining quota)\n  %d calls, %d in / %d out tokens\n", n, i, o }' "$LEDGER"
  exit 0
fi

[[ "$PERMISSION" == "review" ]] || die "--permission $PERMISSION is refused: this lane is review-only"
command -v codex >/dev/null 2>&1 || die "codex is not on PATH. This lane is optional. See docs/delegate.md"
command -v jq    >/dev/null 2>&1 || die "jq is not on PATH"

case "$TYPE" in
  research|review|longread) ;;
  "") die "--type is required (research | review | longread)" ;;
  *)  die "invalid --type '$TYPE' (expected research | review | longread)" ;;
esac

[[ ${#PROMPT_PARTS[@]} -gt 0 ]] || die "no prompt given"
PROMPT="${PROMPT_PARTS[*]}"

if [[ -z "$MODEL" ]]; then
  [[ -f "$ROSTER" ]] && MODEL="$(jq -r '.providers.codex.default // ""' "$ROSTER" | tr -d '\r')"
  [[ -n "$MODEL" && "$MODEL" != REPLACE* ]] || die "no default model. Set providers.codex.default in $ROSTER, or pass --model"
fi

# Same refusal as agy-delegate.sh: found from this script's folder, fails closed.
SECRET_LIB="$BASE/hooks/secret-paths.sh"
[[ -f "$SECRET_LIB" ]] || die "the secret check needs $SECRET_LIB, and it is missing"
# shellcheck source=/dev/null
source "$SECRET_LIB" || die "could not load $SECRET_LIB"
is_secret_target() {
  local p
  for p in "$1" "$(readlink -f -- "$1" 2>/dev/null || true)"; do
    [[ -n "$p" ]] || continue
    is_secret_path "$p" && return 0
    is_secret_store_dir "$p" && return 0
  done
  return 1
}

for f in "${FILES[@]+"${FILES[@]}"}"; do
  is_secret_target "$f" && die "--file is a secret-bearing file, it is never sent to codex: $f"
done
if [[ "$USE_STDIN" -eq 1 && -f /dev/stdin ]]; then
  STDIN_SRC="$(readlink -f /dev/stdin 2>/dev/null || true)"
  [[ -n "$STDIN_SRC" ]] || die "--stdin is a file whose path could not be resolved, so it cannot be checked"
  is_secret_target "$STDIN_SRC" && die "--stdin is a secret-bearing file, it is never sent to codex: $STDIN_SRC"
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

WORKDIR="$(mktemp -d)"
OUT_FILE="$WORKDIR/answer.txt"
EVENTS_FILE="$WORKDIR/events.jsonl"
trap 'rm -rf "$WORKDIR"' EXIT
HARD_TIMEOUT="${CODEX_HARD_TIMEOUT:-360}"

args=(exec --sandbox read-only --skip-git-repo-check --ephemeral --ignore-user-config
      -C "$WORKDIR" -m "$MODEL" -o "$OUT_FILE" --json)
[[ -n "$EFFORT" ]] && args+=(-c "model_reasoning_effort=\"$EFFORT\"")

RC=0
if command -v timeout >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | timeout "$HARD_TIMEOUT" codex "${args[@]}" > "$EVENTS_FILE" 2>&1 || RC=$?
else
  printf '%s' "$PAYLOAD" | codex "${args[@]}" > "$EVENTS_FILE" 2>&1 || RC=$?
fi

# Exit 4 means this account cannot use this model, so retrying is pointless. Quota and
# login errors borrow the same words but fix themselves, so they veto the match and
# stay exit 2. A bare 403 is not matched: a proxy can produce one too.
model_refused() {
  [[ -s "$EVENTS_FILE" ]] || return 1
  grep -qiE 'rate[ _-]?limit|usage limit|quota|too many requests|try again|(status|code)[^0-9]{0,6}(429|401)|unauthorized|not logged in|expired|invalid api key' "$EVENTS_FILE" && return 1
  grep -qiE 'model_not_found|insufficient_permissions?' "$EVENTS_FILE"
}

[[ $RC -ne 124 ]] || die "codex timed out after ${HARD_TIMEOUT}s" 2
if [[ $RC -ne 0 ]]; then
  tail -n 20 "$EVENTS_FILE" >&2 || true
  model_refused && die "model '$MODEL' was refused for this account. Retrying will not help. Check the spelling, or pick another model." 4
  die "codex exec exited $RC" 2
fi

RESPONSE=""
[[ -f "$OUT_FILE" ]] && RESPONSE="$(cat -- "$OUT_FILE")"
if [[ -z "$RESPONSE" ]]; then
  echo "codex-delegate: empty answer. The raw events follow." >&2
  tail -n 20 "$EVENTS_FILE" >&2 || true
  exit 3
fi

printf '%s\n' "$RESPONSE"

{
  JSON_LINE="$(grep -o '^{.*}$' "$EVENTS_FILE" | jq -c -s 'map(select(.type == "turn.completed")) | last // empty' | tr -d '\r' || true)"
  IN_TOK="$(printf '%s' "$JSON_LINE" | jq -r '.usage.input_tokens // 0' | tr -d '\r')"
  OUT_TOK="$(printf '%s' "$JSON_LINE" | jq -r '.usage.output_tokens // 0' | tr -d '\r')"
  mkdir -p "$(dirname "$LEDGER")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$MODEL" "${IN_TOK:-0}" "${OUT_TOK:-0}" "$TYPE" >> "$LEDGER"
} 2>/dev/null || true

echo "[codex ${IN_TOK:-0} in / ${OUT_TOK:-0} out tokens, model $MODEL]" >&2

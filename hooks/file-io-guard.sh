#!/usr/bin/env bash
# file-io-guard.sh: PreToolUse hook on Write, Edit, MultiEdit, Read, Grep, NotebookEdit.
# Rule A: no catastrophic shrink of a memory file.
# Rule B: no Read of a secret file, and no Grep in content mode on one.
# The path set lives in secret-paths.sh, shared with pre-tool-use-guard.sh.
# Fails closed on a payload it cannot read. Always exits 0: the decision is the JSON.

source "$(dirname "${BASH_SOURCE[0]}")/ensure-jq.sh"


# Read the hook payload from stdin.
INPUT=$(cat)


# deny: printf and sed only. Defined before anything that can call it.
deny() {
  esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  exit 0
}

command -v jq >/dev/null 2>&1 || \
  deny "Blocked: file-io-guard could not find jq on PATH, so it could not read the tool payload and could not check it. Failing closed by design"

SECRET_PATHS_LIB="$(dirname "${BASH_SOURCE[0]}")/secret-paths.sh"
if [ -r "$SECRET_PATHS_LIB" ]; then
  # shellcheck source=secret-paths.sh
  . "$SECRET_PATHS_LIB"
else
  deny "Blocked: the shared secret-path definition ($SECRET_PATHS_LIB) is missing, so file-io-guard cannot tell whether this file holds secrets. Failing closed by design: reinstall secret-paths.sh into the hooks directory"
fi


# One jq call. A payload that cannot be parsed is denied, not allowed. Fields are
# joined with 0x1f because a tab is IFS whitespace and would merge empty fields.
# Content length is in bytes, to compare with on-disk size.
JQ_ERRF=$(mktemp)
META=$(printf '%s' "$INPUT" | jq -r '
  [ (.tool_name // ""),
    (.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""),
    (if (.tool_input | type) == "object"
        and (.tool_input | has("content"))
        and ((.tool_input.content | type) == "string")
     then (.tool_input.content | utf8bytelength | tostring)
     else "-1" end),
    (.tool_input.output_mode // ""),
    (.tool_input.glob // "")
  ] | map(tostring | gsub("[\u001f\n\r]"; " ")) | join("\u001f")' 2>"$JQ_ERRF")
JQ_RC=$?
META="${META%$'\r'}"   # jq on Windows can end its line with CRLF
JQ_ERR=$(cat "$JQ_ERRF")
rm -f "$JQ_ERRF"

if [ "$JQ_RC" -ne 0 ]; then
  deny "Blocked: file-io-guard could not parse this tool payload, so the file operation could not be checked. Failing closed by design. jq reported: $JQ_ERR"
fi

IFS=$'\x1f' read -r TOOL FILE_PATH CONTENT_BYTES GREP_MODE GREP_GLOB <<< "$META"
TOOL="${TOOL:-}"; FILE_PATH="${FILE_PATH:-}"; CONTENT_BYTES="${CONTENT_BYTES:--1}"

[ "$TOOL" = "Grep" ] && [ -z "$FILE_PATH" ] && FILE_PATH="$PWD"

[ -n "$FILE_PATH" ] || exit 0


# Rule B: Grep in content mode prints matching lines, which for a secret file are
# the values. Count and file-list modes stay allowed.
if [ "$TOOL" = "Grep" ] && [ "${GREP_MODE:-}" = "content" ]; then
  GREP_HIT=""
  is_secret_path "$FILE_PATH" && GREP_HIT="$FILE_PATH"
  if [ -z "$GREP_HIT" ] && [ -n "${GREP_GLOB:-}" ]; then
    case "$GREP_GLOB" in
      '*'|'**/*'|'**') ;;   # the same as no filter
      *) secret_glob_may_match "$GREP_GLOB" && GREP_HIT="glob $GREP_GLOB" ;;
    esac
  fi
  if [ -z "$GREP_HIT" ] && [ -d "$FILE_PATH" ]; then
    if is_secret_store_dir "$FILE_PATH"; then
      GREP_HIT="$FILE_PATH, a key folder"
    elif TOP_HIT="$(dir_top_secret "$FILE_PATH")"; then
      git -c core.fsmonitor=false -C "$FILE_PATH" check-ignore --no-index -q -- "$TOP_HIT" 2>/dev/null || GREP_HIT="$TOP_HIT"
    fi
  fi
  [ -n "$GREP_HIT" ] && deny "Blocked: a Grep in content mode on $GREP_HIT would print secret values into the transcript. Use output_mode count or files_with_matches, or narrow path or glob so the secret file is not searched"
fi


# Rule B: Read of a secret file.
if [ "$TOOL" = "Read" ] && is_secret_path "$FILE_PATH"; then
  deny "Blocked: $FILE_PATH is a secret-bearing file and reading it would put its contents in the transcript. Reference the variable name instead, or probe the file without printing values (grep -c / grep -q)"
fi


# Rule A: a Write that replaces a memory file of 2048 bytes or more with under half
# its size is denied. Edit is not judged: it carries no whole-file content.
# MEMORY_REWRITE_OK=1 is the escape hatch for a rewrite you really mean.
[ "$TOOL" = "Write" ] || exit 0
[ "${MEMORY_REWRITE_OK:-}" = "1" ] && exit 0
case "$CONTENT_BYTES" in
  ''|*[!0-9]*) exit 0 ;;
esac

NORM="${FILE_PATH//\\//}"
case "$NORM" in
  */memory/*.md) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

EXISTING_BYTES=$(wc -c < "$FILE_PATH")
EXISTING_BYTES="${EXISTING_BYTES//[[:space:]]/}"
case "$EXISTING_BYTES" in
  ''|*[!0-9]*) exit 0 ;;   # unreadable size: no basis to judge, do not invent one
esac

[ "$EXISTING_BYTES" -ge 2048 ] || exit 0

if [ $(( CONTENT_BYTES * 2 )) -lt "$EXISTING_BYTES" ]; then
  deny "Blocked: this Write would replace $FILE_PATH ($EXISTING_BYTES bytes) with only $CONTENT_BYTES bytes: under half its current size. Memory files take surgical edits, never full-file rewrites. Use Edit to change the part you mean, or set MEMORY_REWRITE_OK=1 if a full rewrite really is intended"
fi

exit 0

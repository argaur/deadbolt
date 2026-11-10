#!/usr/bin/env bash
# install.sh: install the deadbolt guards into ~/.claude.
#
#   bash install.sh                  core: guards, canary, drift checks, plan gates
#   bash install.sh --with-delegate  also the optional non-Anthropic delegation lane
#   bash install.sh --dry-run        show what would change, change nothing
#   bash install.sh --uninstall      remove everything this script added
#
# What it touches:
#   ~/.claude/deadbolt/   the hooks and scripts (ours alone)
#   ~/.claude/settings.json    hook entries are merged in. Your settings stay. A
#                              timestamped backup is written first
#   ~/.claude/skills/model-router/, and with --with-delegate, commands/delegate.md and
#   agents/external-delegate.md. A file of yours at those paths is never overwritten.
#
# Running it again is safe: it re-copies our files and adds no duplicate hooks.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BASE="$CLAUDE_DIR/deadbolt"
SETTINGS="$CLAUDE_DIR/settings.json"
MANIFEST="$BASE/MANIFEST.sha256"

MODE=install; DELEGATE=0; DRY=0
for arg in "$@"; do
  case "$arg" in
    --with-delegate) DELEGATE=1 ;;
    --dry-run)       DRY=1 ;;
    --uninstall)     MODE=uninstall ;;
    -h|--help)       awk 'NR>1 { if (/^#/) print; else exit }' "$0"; exit 0 ;;
    *) echo "install: unknown option: $arg" >&2; exit 1 ;;
  esac
done

say()  { echo "install: $*"; }
die()  { echo "install: ERROR: $*" >&2; exit 1; }
run()  { if [ "$DRY" = "1" ]; then echo "  would: $*"; else "$@"; fi; }

# --- prerequisites -----------------------------------------------------------
# The guards rely on bash 4.4 features. On bash 3.2 they would crash before they
# could deny, so an old bash is a hard stop, not a warning.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  die "bash 4.4 or newer is required, this is ${BASH_VERSION:-unknown}. On macOS: brew install bash, and put it first on PATH."
fi
command -v jq >/dev/null 2>&1 || die "jq is required. See https://jqlang.org/download/"
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  die "sha256sum or shasum is required, for the drift check."
fi
if command -v claude >/dev/null 2>&1; then
  say "found Claude Code $(claude --version 2>/dev/null | head -1 | tr -d '\r')"
else
  say "note: 'claude' is not on PATH. Hooks take effect in your next Claude Code session."
fi

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

backup_settings() {
  [ -f "$SETTINGS" ] || return 0
  local b; b="$SETTINGS.bak-deadbolt-$(date +%Y%m%d-%H%M%S)"
  run cp "$SETTINGS" "$b"
  say "settings backup: $b"
}

write_settings() {  # write_settings <jq-output-file>
  jq empty "$1" >/dev/null 2>&1 || die "merged settings are not valid JSON, nothing was changed"
  # jq on Windows can write CRLF.
  tr -d '\r' < "$1" > "$SETTINGS.tmp.$$"
  mv "$SETTINGS.tmp.$$" "$SETTINGS"
  rm -f "$1"
}

# --- uninstall ---------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
  if [ -f "$SETTINGS" ]; then
    jq empty "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON, fix it first"
    backup_settings
    if [ "$DRY" = "0" ]; then
      TMP="$(mktemp)"
      jq --slurpfile d "$SRC/examples/settings.delegate.json" '
        def ours: (.command // "") | contains("deadbolt/");
        (if .hooks then
           .hooks |= (with_entries(
             .value |= (map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0))))
             | with_entries(select((.value | length) > 0)))
           | (if .hooks == {} then del(.hooks) else . end)
         else . end)
        | (if .permissions.ask then
             .permissions.ask -= $d[0].permissions.ask
             | (if .permissions.ask == [] then del(.permissions.ask) else . end)
             | (if .permissions == {} then del(.permissions) else . end)
           else . end)' "$SETTINGS" > "$TMP"
      write_settings "$TMP"
    fi
  fi
  if [ -f "$MANIFEST" ]; then
    while read -r _ rel; do
      rel="${rel#\*}"
      case "$rel" in
        deadbolt/*) ;;
        *) run rm -f "$CLAUDE_DIR/$rel" ;;
      esac
    done < "$MANIFEST"
    run rmdir "$CLAUDE_DIR/skills/model-router" 2>/dev/null || true
  fi
  run rm -rf "$BASE"
  say "removed. Settings backups stay in $CLAUDE_DIR, delete them when you are sure."
  exit 0
fi

# --- install -----------------------------------------------------------------
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" >/dev/null 2>&1 || die "$SETTINGS is not valid JSON. Fix it first, nothing was changed."
fi

run mkdir -p "$BASE/hooks" "$BASE/scripts" "$CLAUDE_DIR/skills/model-router"
for f in "$SRC"/hooks/*.sh; do
  case "${f##*/}" in
    model-roster-check.sh) [ "$DELEGATE" = "1" ] || continue ;;
  esac
  run cp "$f" "$BASE/hooks/"
done
for f in plan-gate.sh verify-install.sh stale-doc-check.sh enforcement-check.sh; do
  run cp "$SRC/scripts/$f" "$BASE/scripts/"
done

# Never overwrite a file of yours. An identical file counts as ours.
EXTRA=()
place() {  # place <repo-relative source> <path under ~/.claude>
  local from="$SRC/$1" to="$CLAUDE_DIR/$2"
  if [ -f "$to" ] && ! cmp -s "$from" "$to" && ! grep -qF "$2" "$MANIFEST" 2>/dev/null; then
    say "skipped $2: you already have a different file there"
    return 0
  fi
  run mkdir -p "$(dirname "$to")"
  run cp "$from" "$to"
  EXTRA+=("$2")
}
place skills/model-router/SKILL.md skills/model-router/SKILL.md

if [ "$DELEGATE" = "1" ]; then
  run cp "$SRC/scripts/agy-delegate.sh" "$SRC/scripts/codex-delegate.sh" "$BASE/scripts/"
  place commands/delegate.md commands/delegate.md
  place agents/external-delegate.md agents/external-delegate.md
  if [ ! -f "$BASE/models.json" ]; then
    run cp "$SRC/examples/models.example.json" "$BASE/models.json"
    say "edit $BASE/models.json and set your default models before using /delegate"
  fi
fi

# --- merge settings ----------------------------------------------------------
# A hook is added only if its command is not already registered for that event.
MERGE='
  def addhooks($new):
    reduce ($new | to_entries[]) as $ev (.;
      reduce $ev.value[] as $entry (.;
        (.hooks[$ev.key] // []) as $cur
        | ([$cur[].hooks[]?.command]) as $have
        | ($entry | .hooks |= map(select(.command as $c | $have | index($c) | not))) as $fresh
        | if ($fresh.hooks | length) > 0
          then .hooks[$ev.key] = ($cur + [$fresh])
          else . end));
  .[0] | .hooks //= {} | addhooks($core[0].hooks)
  | if $with == "1" then
      addhooks($del[0].hooks)
      | .permissions.ask = ((.permissions.ask // []) + $del[0].permissions.ask | unique)
    else . end'

if [ "$DRY" = "1" ]; then
  say "would merge hook entries into $SETTINGS"
else
  backup_settings
  CURRENT="$(mktemp)"
  if [ -f "$SETTINGS" ]; then cp "$SETTINGS" "$CURRENT"; else printf '{}' > "$CURRENT"; fi
  TMP="$(mktemp)"
  jq -s --arg with "$DELEGATE" \
     --slurpfile core "$SRC/examples/settings.json" \
     --slurpfile del "$SRC/examples/settings.delegate.json" \
     "$MERGE" "$CURRENT" > "$TMP"
  rm -f "$CURRENT"
  write_settings "$TMP"
fi

# --- manifest and first canary -----------------------------------------------
if [ "$DRY" = "1" ]; then
  say "dry run: nothing was changed"
  exit 0
fi

NEW_MANIFEST="$(mktemp)"
(
  cd "$CLAUDE_DIR"
  for rel in deadbolt/hooks/*.sh deadbolt/scripts/*.sh "${EXTRA[@]}"; do
    hash_file "$rel"
  done
) | tr -d '\r' > "$NEW_MANIFEST"
mv "$NEW_MANIFEST" "$MANIFEST"

OUT="$(bash "$BASE/hooks/hook-canary.sh" "$SETTINGS")"
if [ -n "$OUT" ]; then
  MSG="$(echo "$OUT" | jq -r '.systemMessage' | tr -d '\r')"
  echo "$MSG" >&2
  case "$MSG" in
    *"- FAIL"*) die "the canary reported a problem right after install. Your settings backup is listed above." ;;
  esac
fi

say "installed $(wc -l < "$MANIFEST" | tr -d ' ') files. The canary passed: all three guards deny and allow correctly."
say "start a new Claude Code session to load the hooks."

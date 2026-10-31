#!/usr/bin/env bash
# deploy-preflight-guard.sh: PreToolUse hook on Bash and PowerShell.
# Blocks a Vercel or Railway deploy unless the project's CLAUDE.md records a
# `Deploy target:` line. This stops a deploy to the wrong account by construction.
# Add your own platform by extending RE_VERCEL and RE_RAILWAY below.


# Read the hook payload from stdin. Output is one JSON deny, or nothing.
INPUT=$(cat)

deny() {
  esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  exit 0
}


# Command extraction, same fail-closed walk as pre-tool-use-guard.sh.
HAS_COMMAND_KEY=0
case "$INPUT" in
  *'"command"'*) HAS_COMMAND_KEY=1 ;;
esac

[ "$HAS_COMMAND_KEY" = "0" ] && exit 0

PARSE_OK=0
CMD=""

rest="${INPUT#*'"command"'}"

while [ "${rest#[[:space:]]}" != "$rest" ]; do rest="${rest#[[:space:]]}"; done
case "$rest" in
  :*) rest="${rest#:}"
      while [ "${rest#[[:space:]]}" != "$rest" ]; do rest="${rest#[[:space:]]}"; done
      case "$rest" in
        '"'*) rest="${rest#\"}"
              while : ; do
                chunk="${rest%%\"*}"
                if [ "$chunk" = "$rest" ]; then
                  break
                fi
                bs="${chunk##*[!\\]}"
                CMD="$CMD$chunk"
                rest="${rest#"$chunk"}"
                rest="${rest#\"}"
                if [ $(( ${#bs} % 2 )) -eq 0 ]; then
                  PARSE_OK=1
                  break
                fi
                CMD="$CMD\""   # escaped quote: keep it, unescape below
              done ;;
      esac ;;
esac

if [ "$PARSE_OK" = "1" ] && [ -n "$CMD" ]; then
  CMD=$(printf '%s' "$CMD" | sed 's/\\\\/\x01/g; s/\\"/"/g; s/\\t/ /g; s/\\n/\n/g; s/\\r/\n/g; s/\x01/\\/g')
fi

if [ "$PARSE_OK" != "1" ] || [ -z "$CMD" ]; then
  deny "Blocked: the deploy pre-flight guard could not parse this tool payload: a \"command\" key is present but its value could not be extracted, so the guard cannot tell whether this is a deploy. It will not let an unreadable command through: failing closed by design. Re-issue the command, or run it yourself in a real terminal."
fi


# Deploy detection. The anchor before the binary name keeps `echo vercel --prod` and
# commit messages out. RE_WRAP adds optional VAR=x, npx, bunx, pnpm dlx and yarn dlx.
# The right side of =~ stays unquoted, or bash treats the regex as a literal string.
NLD=$'\n'
HSD=$' \t\v\f\r'
RE_WRAP='([A-Za-z_][A-Za-z0-9_]*=[^'"$HSD$NLD"';&|]*['"$HSD"']+)*((npx|bunx|(pnpm|yarn)['"$HSD"']+dlx)['"$HSD"']+(-{1,2}[A-Za-z0-9][A-Za-z0-9=_.-]*['"$HSD"']+)*)?'
RE_VER='(@[A-Za-z0-9._-]+)?'
RE_VERCEL='(^|['"$NLD"']|[|;&]['"$HSD"']*)'"$RE_WRAP"'vercel'"$RE_VER"'(['"$HSD"']+[^'"$HSD$NLD"';&|]+)*['"$HSD"']+(--prod|deploy|promote|rollback|redeploy|--target(=|['"$HSD"']+)production)([^A-Za-z0-9_-]|$)'
RE_RAILWAY='(^|['"$NLD"']|[|;&]['"$HSD"']*)'"$RE_WRAP"'railway'"$RE_VER"'(['"$HSD"']+[^'"$HSD$NLD"';&|]+)*['"$HSD"']+(up|deploy)([^A-Za-z0-9_-]|$)'
IS_DEPLOY=false
DEPLOY_MATCH=""
if [[ $CMD =~ $RE_VERCEL ]]; then IS_DEPLOY=true; DEPLOY_MATCH="${BASH_REMATCH[0]}"
elif [[ $CMD =~ $RE_RAILWAY ]]; then IS_DEPLOY=true; DEPLOY_MATCH="${BASH_REMATCH[0]}"; fi
[ "$IS_DEPLOY" = "false" ] && exit 0


# resolve_dir <word> <base>: RD = the word unquoted, home-expanded, absolute.
resolve_dir() {
  RD="$1"
  RD="${RD#\"}"; RD="${RD%\"}"; RD="${RD#\'}"; RD="${RD%\'}"
  case "$RD" in
    '~')               RD="$HOME" ;;
    '~/'*)             RD="$HOME/${RD#'~/'}" ;;
    '$HOME'|'${HOME}') RD="$HOME" ;;
    '$HOME/'*)         RD="$HOME/${RD#'$HOME/'}" ;;
    '${HOME}/'*)       RD="$HOME/${RD#'${HOME}/'}" ;;
  esac
  case "$RD" in
    /*|[A-Za-z]:*) ;;
    *) RD="$2/$RD" ;;
  esac
}

# Which project is deployed: the last cd before the deploy, then --cwd, then the
# positional path. Otherwise CLAUDE_PROJECT_DIR, otherwise the working folder.
DIR=""
PRE_DEPLOY="${CMD%%"$DEPLOY_MATCH"*}"
LAST_CD=$(printf '%s' "$PRE_DEPLOY" | grep -oE "cd[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" | tail -1)
BASE_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -n "$LAST_CD" ]; then
  resolve_dir "$(printf '%s' "$LAST_CD" | sed -E 's/^cd[[:space:]]+//')" "$BASE_DIR"
  DIR="$RD"
fi
[ -z "$DIR" ] && DIR="$BASE_DIR"

DEPLOY_SEG="${CMD#"$PRE_DEPLOY"}"
DEPLOY_SEG=$(printf '%s' "$DEPLOY_SEG" | sed -E 's/^[;&|[:space:]]+//')
DEPLOY_SEG="${DEPLOY_SEG%%[;&|$NLD]*}"
CWD_ARG=$(printf '%s' "$DEPLOY_SEG" | grep -oE -- "--cwd([[:space:]]+|=)(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" | tail -1)
if [ -n "$CWD_ARG" ]; then
  resolve_dir "$(printf '%s' "$CWD_ARG" | sed -E 's/^--cwd([[:space:]]+|=)//')" "$DIR"
  DIR="$RD"
fi

if [[ $DEPLOY_SEG =~ (^|[^A-Za-z0-9_./-])vercel(@[A-Za-z0-9._-]+)?([[:space:]]|$) ]]; then
  AFTER="${DEPLOY_SEG#*"${BASH_REMATCH[0]}"}"
  set -f
  # shellcheck disable=SC2206
  VWORDS=($AFTER)
  set +f
  skip=0; sub=""
  for w in "${VWORDS[@]}"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$w" in
      --cwd|--scope|-S|--token|-t|--env|-e|--build-env|-b|--meta|-m|--target|--archive|-A|--local-config|--global-config|-Q|--regions) skip=1; continue ;;
      -*) continue ;;
    esac
    if [ -z "$sub" ]; then
      case "$w" in
        deploy) sub=deploy; continue ;;
        promote|rollback|redeploy) break ;;
      esac
    fi
    resolve_dir "$w" "$DIR"
    DIR="$RD"
    break
  done
fi


# Walk up to the nearest CLAUDE.md. It must carry a Deploy target: line.
FOUND=""
d="$DIR"
while : ; do
  if [ -f "$d/CLAUDE.md" ]; then FOUND="$d/CLAUDE.md"; break; fi
  parent=$(dirname "$d")
  [ "$parent" = "$d" ] && break
  d="$parent"
done

if [ -n "$FOUND" ] && grep -qiE '^[[:space:]]*(\*\*)?Deploy target(\*\*)?:' "$FOUND"; then
  exit 0
fi

if [ -n "$FOUND" ]; then
  deny "Blocked: $FOUND has no 'Deploy target:' line. Record the confirmed account/project ID + runtime (edge/node) there before deploying. Never assume a default target."
fi

deny "Blocked: no CLAUDE.md found at or above $DIR, so the deploy target was never confirmed for this project. Create one with a 'Deploy target:' line (account/project ID + runtime) before deploying. Never assume a default target."

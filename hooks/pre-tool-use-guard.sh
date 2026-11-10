#!/usr/bin/env bash
# pre-tool-use-guard.sh: PreToolUse hook on Bash and PowerShell.
# Denies forbidden commands. Never modifies them. The block applies to the model
# only: you can still run any of these yourself in a real terminal.
#
# Rules: docs/ENFORCEMENT.md. Known limits: docs/guards.md.
# Bash 4.4 or newer. No python and no jq, so a missing tool cannot fail it open.


# Read the hook payload from stdin. Output is one JSON deny, or nothing.
INPUT=$(cat)


# deny: pure printf and sed, so no interpreter can go missing and fail open.
deny() {
  esc=$(printf '%s' "$1 (deadbolt guard. Run it yourself in a real terminal if you truly need it)" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
  exit 0
}


# Command extraction. Pure bash: walks the JSON string to the first unescaped quote.
# A payload with no command key is not a command tool, so it passes.
# A payload with a command key that cannot be read is DENIED. Never fail open.
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
  deny "Blocked: this guard could not parse the tool payload: a \"command\" key is present but its value could not be extracted, so the command could not be checked. Failing closed by design"
fi


# A commit message is data. Its quoted body is blanked before the checks run, so
# a message can name a forbidden flag. Flags outside the quotes are still checked,
# and $(...) or backtick bodies inside a message are added back, because bash runs them.
SCRUB="$CMD"
RE_GIT_COMMIT='(^|[|;&({"'"'"'[:space:]])git[[:space:]]+commit([[:space:]]|$)'
RE_SEG_COMMIT='(^|[[:space:]{])git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'
RE_MSG_BODY='^(-m|--message)(=|[[:space:]]*)("[^"]*"|'"'"'[^'"'"']*'"'"')'
scrub_commit_bodies() {
  local s="$1" out="" seg="" i=0 n=${#1} c prev rest body
  while (( i < n )); do
    c="${s:i:1}"
    case "$c" in
      '"'|"'")
        rest="${s:i+1}"
        if [[ $rest != *"$c"* ]]; then out+="${s:i}"; break; fi
        body="${rest%%"$c"*}"
        out+="$c$body$c"; seg+="$c$body$c"; i=$((i + ${#body} + 2)); continue ;;
      ';'|'|'|'&'|'('|$'\n')
        out+="$c"; seg=""; i=$((i+1)); continue ;;
      -)
        prev="${s:i-1:1}"; (( i == 0 )) && prev=" "
        if [[ $prev =~ [[:space:]{] ]] && [[ $seg =~ $RE_SEG_COMMIT ]] && [[ ${s:i} =~ $RE_MSG_BODY ]]; then
          body="${BASH_REMATCH[3]:0:1}"
          out+="${BASH_REMATCH[1]} ${body}SCRUBBED${body}"; seg+=" SCRUBBED"
          i=$((i + ${#BASH_REMATCH[0]})); continue
        fi ;;
    esac
    out+="$c"; seg+="$c"; i=$((i+1))
  done
  printf '%s' "$out"
}
if [[ $CMD =~ $RE_GIT_COMMIT ]]; then
  SCRUB=$(scrub_commit_bodies "$CMD")
  [ -n "$SCRUB" ] || SCRUB="$CMD"

  if [ "$SCRUB" != "$CMD" ]; then
    SUBST="" rest="$CMD"
    while [[ $rest == *'$('* ]]; do rest="${rest#*'$('}"; SUBST+=$'\n'"$rest"; done
    rest="$CMD"
    while [[ $rest == *'`'*'`'* ]]; do
      rest="${rest#*\`}"; SUBST+=$'\n'"${rest%%\`*}"; rest="${rest#*\`}"
    done
    if [ -n "$SUBST" ]; then
      KEPT="" term="" hd_re='^[[:space:]]*cat[[:space:]]+<<-?[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
      while IFS= read -r line; do
        if [ -n "$term" ]; then
          [ "${line#"${line%%[![:space:]]*}"}" = "$term" ] && term=""
          continue
        fi
        KEPT+=$'\n'"$line"
        [[ $line =~ $hd_re ]] && [[ $line != *'|'* ]] && term="${BASH_REMATCH[1]}"
      done <<< "$SUBST"
      SCRUB+="$KEPT"
    fi
  fi
fi


# Shared fragments: home and drive roots in PowerShell and cmd notation.
Q="\"'"
QB="$Q"'`'
PS_ROOT='(\$HOME|\$env:USERPROFILE|\$env:HOMEDRIVE|(^|['"$QB"'[:space:]])~(['"$QB"'[:space:]]|\\|$)|[A-Za-z]:\\+(['"$QB"'[:space:]]|$)|[A-Za-z]:\\Users\\[^\\'"$QB"']+\\*(['"$QB"']|[[:space:]]*$))'
CMD_ROOT='(%USERPROFILE%|%HOMEDRIVE%|%HOMEPATH%|%SYSTEMDRIVE%|[A-Za-z]:\\+(\*|['"$QB"'[:space:]]|$)|[A-Za-z]:\\Users\\[^\\'"$QB"']+\\*(['"$QB"']|[[:space:]]*$))'


# Check 1: force push. --force-with-lease stays allowed.
RE_GIT_PREFIX='git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--?[A-Za-z][A-Za-z-]*(=[^[:space:]]*)?))*'
RE_PUSH_FORCE="$RE_GIT_PREFIX"'[[:space:]]+push[^|;&]*[[:space:]]((--force|-[a-zA-Z]*f[a-zA-Z]*)([^A-Za-z0-9=_-]|$)|\+[A-Za-z0-9_./-])'
RE_FORCE_WITH_LEASE='force-with-lease'
if [[ $SCRUB =~ $RE_PUSH_FORCE ]] && ! [[ $SCRUB =~ $RE_FORCE_WITH_LEASE ]]; then
  deny "Blocked: git push --force"
fi


# Check 2: skipping git hooks.
RE_NO_VERIFY='git[[:space:]][^|;&]*--no-verify'
RE_COMMIT_N="$RE_GIT_PREFIX"'[[:space:]]+commit[^|;&]*[[:space:]]-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'
if [[ $SCRUB =~ $RE_NO_VERIFY ]] || [[ $SCRUB =~ $RE_COMMIT_N ]]; then
  deny "Blocked: --no-verify bypasses hooks"
fi


# Check 3a: recursive delete of home or root, bash form.
NL=$'\n'
RM_FLAGS='(-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*|(-[rR]|--recursive)[[:space:]]+(-f|--force)|(-f|--force)[[:space:]]+(-[rR]|--recursive))'
RM_TARGET='("?\$\{?HOME\}?"?/?\*?|"?~/?\*?"?|/\*?|/[a-z]/?\*?|"?/(c/Users|home|Users)/[^/"]+/?\*?"?)'
RE_RM_ROOT='(^|[|;&({'"$Q"'[:space:]])rm[[:space:]]+'"$RM_FLAGS"'[[:space:]]+(--[[:space:]]+)?'"$RM_TARGET"'[[:space:]]*($|['"$NL"';&|)'"$Q"'])'
if [[ $SCRUB =~ $RE_RM_ROOT ]]; then
  deny "Blocked: recursive delete of home/root"
fi


# Check 3b: the same in PowerShell. Case-insensitive, so only these tests use nocasematch.
RE_PS_DEL_VERB='(^|[|;&({[:space:]]|^)(remove-item|rmdir|rd|ri|rm|del|erase)[[:space:]]'
RE_PS_RECURSE='(^|[[:space:]])-recurse([[:space:]]|$)'
shopt -s nocasematch
HIT_3B=0
[[ $SCRUB =~ $RE_PS_DEL_VERB ]] && [[ $SCRUB =~ $RE_PS_RECURSE ]] && [[ $SCRUB =~ $PS_ROOT ]] && HIT_3B=1
shopt -u nocasematch
if [ "$HIT_3B" = "1" ]; then
  deny "Blocked: recursive delete of home/root"
fi


# Check 3c: the same in cmd.exe (rd /s /q).
RE_CMD_DEL_VERB='(^|[|;&({'"$Q"'[:space:]])(rd|rmdir|del|erase)[[:space:]]'
RE_CMD_SLASH_S='(^|[[:space:]])/s([[:space:]]|$)'
shopt -s nocasematch
HIT_3C=0
[[ $SCRUB =~ $RE_CMD_DEL_VERB ]] && [[ $SCRUB =~ $RE_CMD_SLASH_S ]] && [[ $SCRUB =~ $CMD_ROOT ]] && HIT_3C=1
shopt -u nocasematch
if [ "$HIT_3C" = "1" ]; then
  deny "Blocked: recursive delete of home/root"
fi


# Check 4: reset --hard chained with a push.
RE_RESET_PUSH='git[[:space:]]+reset[[:space:]]+--hard[^|;&]*(&&|;|\|\|)[^|;&]*git[[:space:]]+push'
if [[ $SCRUB =~ $RE_RESET_PUSH ]]; then
  deny "Blocked: reset --hard + push chain"
fi


# Check 5: printing a secret-shaped variable. A real variable reference is required,
# so the English word 'token' in a heading passes. Names must be upper case.
PRINT_CTX='(^|[|;&({'"$Q"'[:space:]])(echo|printf|print|printenv|cat|type|more|write-host|write-output|write-error|out-host|get-content|gc|puts|console\.log|console\.writeline|system\.out\.println|system\.out\.print)([('"$Q"'[:space:]]|$)[^|;&]*'
SECRET_ID='[A-Za-z0-9_]*(KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|DATABASE_URL)[A-Za-z0-9_]*'
ENV_IDIOM='(os\.environ|process\.env|getenvironmentvariable|getenv|[^A-Za-z0-9_]?ENV)(\.get)?[[:space:]]*[.[(][[:space:]]*\\?["'"'"']?'
RE_SECRET_SIGIL="$PRINT_CTX"'(\$\{?(env:)?|%)'"$SECRET_ID"
RE_SECRET_IDIOM="$PRINT_CTX$ENV_IDIOM$SECRET_ID"
shopt -s nocasematch
HIT_5=0
KEYWORD_HIT=""
if [[ $SCRUB =~ $RE_SECRET_SIGIL ]]; then
  HIT_5=1; KEYWORD_HIT="${BASH_REMATCH[6]}"
elif [[ $SCRUB =~ $RE_SECRET_IDIOM ]]; then
  HIT_5=1; KEYWORD_HIT="${BASH_REMATCH[6]}"
fi
shopt -u nocasematch
if [ "$HIT_5" = "1" ] && [ -n "$KEYWORD_HIT" ]; then
  UPPER_HIT=$(printf '%s' "$KEYWORD_HIT" | tr '[:lower:]' '[:upper:]')
  [ "$KEYWORD_HIT" = "$UPPER_HIT" ] || HIT_5=0
fi
if [ "$HIT_5" = "1" ]; then
  deny "Blocked: command output would print a secret-shaped variable (KEY/SECRET/TOKEN/PASSWORD/DATABASE_URL): reference the var name, never its value"
fi


# Check 5b: printenv with a secret-shaped argument. Bare printenv is allowed on purpose.
RE_PRINTENV='(^|[|;&({'"$Q"'[:space:]])printenv[[:space:]]+[^|;&]*'"$SECRET_ID"
shopt -s nocasematch
HIT_5B=0
if [[ $SCRUB =~ $RE_PRINTENV ]]; then HIT_5B=1; fi
shopt -u nocasematch
if [ "$HIT_5B" = "1" ]; then
  deny "Blocked: command output would print a secret-shaped variable (KEY/SECRET/TOKEN/PASSWORD/DATABASE_URL): reference the var name, never its value"
fi


# Check 5c: the PowerShell Env: drive.
RE_ENV_DRIVE='(^|[|;&({'"$Q"'[:space:]])(get-item|gi|get-childitem|gci|get-content|gc|cat|dir|ls|write-host|write-output|echo)[[:space:]]+([^|;&]*[^A-Za-z0-9_])?env:'"$SECRET_ID"
shopt -s nocasematch
HIT_5C=0
if [[ $SCRUB =~ $RE_ENV_DRIVE ]]; then HIT_5C=1; fi
shopt -u nocasematch
if [ "$HIT_5C" = "1" ]; then
  deny "Blocked: command output would print a secret-shaped variable (KEY/SECRET/TOKEN/PASSWORD/DATABASE_URL): reference the var name, never its value"
fi


# Check 5d: bash indirect expansion of a secret-shaped name.
RE_INDIRECT="$PRINT_CTX"'\$\{![A-Za-z_][A-Za-z0-9_]*\}'
RE_SECRET_ASSIGN='(^|[|;&({[:space:]])[A-Za-z_][A-Za-z0-9_]*=["'"'"']?'"$SECRET_ID"'["'"'"']?([[:space:];&|]|$)'
if [[ $SCRUB =~ $RE_INDIRECT ]] && [[ $SCRUB =~ $RE_SECRET_ASSIGN ]]; then
  deny "Blocked: command output would print a secret-shaped variable (KEY/SECRET/TOKEN/PASSWORD/DATABASE_URL): reference the var name, never its value"
fi


# Check 6: python3 where only python exists. Disables itself when python3 is installed.
if printf '%s' "$SCRUB" | grep -qE '(^|[|;&(]|["'"'"'][[:space:]]*)[[:space:]]*python3\b' \
   && ! command -v python3 >/dev/null 2>&1; then
  deny "Blocked: python3 is not on PATH in this environment: use 'python' instead"
fi


# Check 7: a quoted Windows path ending in a backslash breaks bash quoting.
RE_TRAILING_BS='[A-Za-z]:\\[^"]*\\"'
if [[ $SCRUB =~ $RE_TRAILING_BS ]]; then
  deny "Blocked: quoted Windows path ends in a trailing backslash before the closing quote, which breaks bash quote-parsing: drop the trailing backslash or use a forward slash"
fi


# Check 8: reading a secret file through a shell verb. The path set lives in
# secret-paths.sh and is shared with file-io-guard.sh, so the two cannot drift.
# The command is split into segments, wrappers and shell -c bodies are unwrapped,
# and each read verb's arguments are judged. grep passes only in count, list or
# quiet form. A path that comes from a variable is denied, because it cannot be judged.
SECRET_PATHS_LIB="$(dirname "${BASH_SOURCE[0]}")/secret-paths.sh"
CHECK8_VERBS=" cat head tail less more type get-content gc "
CHECK8_VERBS="$CHECK8_VERBS sed awk gawk nl od xxd hexdump strings base64 tac rev sort uniq cut bat cp "
CHECK8_VERBS="$CHECK8_VERBS diff cmp comm paste join fold fmt column iconv dd jq yq look split openssl gpg curl wget scp rsync tar zip 7z gzip bzip2 xz zstd zcat "
CHECK8_CODE_VERBS=" node python python3 py perl ruby php deno bun lua "
CHECK8_GREP_VERBS=" grep egrep fgrep rg findstr select-string sls "
SHELL_WRAPPERS=" bash sh zsh dash ksh pwsh powershell cmd "

norm_word() {
  NW="${1//\"/}"; NW="${NW//\'/}"; NW="${NW,,}"
  NW="${NW##*/}"; NW="${NW##*\\}"; NW="${NW%.exe}"
}

SPLIT_RE='^[[:space:]]*(("[^"]*"|'"'"'[^'"'"']*'"'"'|\\.|[^[:space:]"'"'"'\\])+)'
split_words() {
  local s="$1" rest
  EW=()
  while [[ $s =~ $SPLIT_RE ]]; do
    EW+=("${BASH_REMATCH[1]}")
    s="${s:${#BASH_REMATCH[0]}}"
  done
  if [[ $s =~ [^[:space:]] ]]; then
    set -f
    # shellcheck disable=SC2206
    rest=($s)
    set +f
    EW+=("${rest[@]}")
  fi
}

effective_words() {
  split_words "$1"
  while [ ${#EW[@]} -gt 0 ]; do
    if [[ ${EW[0]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then EW=("${EW[@]:1}"); continue; fi
    norm_word "${EW[0]}"
    case "$NW" in
      env|exec|nohup|builtin|sudo|stdbuf|time|nice)
        EW=("${EW[@]:1}")
        while [ ${#EW[@]} -gt 0 ] && [[ ${EW[0]} == -* ]]; do
          case "${EW[0]}" in
            -n|-u|-C|-g|--chdir|--unset|--user|--group) EW=("${EW[@]:2}") ;;
            *) EW=("${EW[@]:1}") ;;
          esac
        done ;;
      timeout)
        EW=("${EW[@]:1}")
        while [ ${#EW[@]} -gt 0 ] && [[ ${EW[0]} == -* ]]; do
          case "${EW[0]}" in
            -s|-k|--signal|--kill-after) EW=("${EW[@]:2}") ;;
            *) EW=("${EW[@]:1}") ;;
          esac
        done
        [ ${#EW[@]} -gt 0 ] && EW=("${EW[@]:1}") ;;     # the duration
      command)
        case "${EW[1]:-}" in -v|-V) return 0 ;; esac
        EW=("${EW[@]:1}")
        [ "${EW[0]:-}" = "-p" ] && EW=("${EW[@]:1}") ;;
      *) return 0 ;;
    esac
  done
}

SEGS=(); SEG_WRAPPED=()
seg_split() {   # seg_split <text> <wrapped flag>
  local t="$1" s
  t="${t//\$(/\$__S$NL}"; t="${t//\`/\$__S$NL}"; t="${t//(/$NL}"; t="${t//)/$NL}"
  t="${t//|/$NL}"; t="${t//;/$NL}"; t="${t//&/$NL}"
  while IFS= read -r s; do
    [[ $s =~ ^[[:space:]]*$ ]] && continue
    SEGS+=("$s"); SEG_WRAPPED+=("$2")
  done <<< "$t"
}
strip_data_heredocs() {   # prints $1 with cat/tee heredoc bodies removed
  local line out="" term="" re='<<-?[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line; do
    if [ -n "$term" ]; then
      local bare="${line#"${line%%[![:space:]]*}"}"
      [ "$bare" = "$term" ] && term=""
      continue
    fi
    out+="$line$NL"
    if [[ $line =~ $re ]]; then
      local want="${BASH_REMATCH[1]}"
      effective_words "${line%%[|;&]*}"
      norm_word "${EW[0]:-}"
      case "$NW" in
        cat|tee) case "$line" in *'|'*) ;; *) term="$want" ;; esac ;;
      esac
    fi
  done <<< "$1"
  printf '%s' "$out"
}
shell_segments() {
  local i=0 j body lw
  SEGS=(); SEG_WRAPPED=()
  seg_split "$(strip_data_heredocs "$SCRUB")" 0
  while [ $i -lt ${#SEGS[@]} ] && [ $i -lt 200 ]; do
    effective_words "${SEGS[$i]}"
    norm_word "${EW[0]:-}"
    case "$SHELL_WRAPPERS" in
      *" $NW "*)
        for ((j=1; j<${#EW[@]}; j++)); do
          lw="${EW[$j],,}"
          if [[ $lw =~ ^-[a-z]*c$ ]] || [[ $lw =~ ^-com(m(a(nd?)?)?)?$ ]] || [ "$lw" = "/c" ] || [ "$lw" = "/k" ]; then
            body="${EW[*]:$((j+1))}"
            body="${body//\"/}"; body="${body//\'/}"
            seg_split "$body" 1
            break
          fi
        done ;;
    esac
    i=$((i+1))
  done
}
shell_segments

expand_home() {
  HOMEX="$1"
  case "$HOMEX" in
    '~')                HOMEX="$HOME" ;;
    '~/'*)              HOMEX="$HOME/${HOMEX#'~/'}" ;;
    '$HOME'|'${HOME}')  HOMEX="$HOME" ;;
    '$HOME/'*)          HOMEX="$HOME/${HOMEX#'$HOME/'}" ;;
    '${HOME}/'*)        HOMEX="$HOME/${HOMEX#'${HOME}/'}" ;;
    '$env:USERPROFILE'*) HOMEX="$HOME${HOMEX#'$env:USERPROFILE'}" ;;
    '%USERPROFILE%'*)   HOMEX="$HOME${HOMEX#'%USERPROFILE%'}" ;;
  esac
}

check8_token() {
  local raw="$1" mode="$2" v e d top
  raw="${raw//\"/}"; raw="${raw//\'/}"
  [ -n "$raw" ] || return 1
  case "$raw" in -*) return 1 ;; esac
  local cands=("$raw") c variants=()
  case "$raw" in *=*) cands+=("${raw#*=}") ;; esac
  for c in "${cands[@]}"; do case "$c" in @?*) cands+=("${c#@}") ;; esac; done
  for c in "${cands[@]}"; do
    expand_home "$c"; variants+=("$HOMEX")
    case "$HOMEX" in */*|*:*) ;; *\\*) variants+=("${HOMEX//\\/}") ;; esac
  done
  for v in "${variants[@]}"; do
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      if is_secret_path "$e"; then CHECK8_HIT="$1"; return 0; fi
      case "$e" in
        *[*?[]*)
          if secret_glob_may_match "$e"; then CHECK8_HIT="$1"; return 0; fi
          case "$e" in /*|[A-Za-z]:*) d="$e" ;; *) d="$CHECK8_CWD/$e" ;; esac
          while IFS= read -r f; do
            [ -n "$f" ] && is_secret_path "$f" && { CHECK8_HIT="$1"; return 0; }
          done < <(compgen -G "$d" 2>/dev/null) ;;
      esac
      [ "$mode" = "none" ] && continue
      case "$e" in /*|[A-Za-z]:*) d="$e" ;; *) d="$CHECK8_CWD/$e" ;; esac
      if is_secret_store_dir "$d"; then CHECK8_HIT="$1"; return 0; fi
      if [ "$mode" = "visible" ]; then
        top="$(dir_top_secret "$d" visible)" && ! git -c core.fsmonitor=false -C "$d" check-ignore --no-index -q -- "$top" 2>/dev/null \
          && { CHECK8_HIT="$top"; return 0; }
      else
        top="$(dir_top_secret "$d")" && { CHECK8_HIT="$top"; return 0; }
      fi
    done < <(expand_braces "$v")
  done
  return 1
}

grep_safe() {
  local verb="$1" tok mode=0 letters modes body; shift
  case "$verb" in
    select-string|sls) for tok; do [ "${tok,,}" = "-quiet" ] && return 0; done; return 1 ;;
    findstr) return 1 ;;
    rg) letters='clqinswxFHLuU'; modes='clq' ;;
    *)  letters='clLqinsrRvEFwxHh'; modes='clLq' ;;
  esac
  for tok; do
    case "$tok" in
      --) break ;;
      --count|--count-matches|--files-with-matches|--files-without-match|--quiet|--silent) mode=1 ;;
      --ignore-case|--recursive|--line-number|--fixed-strings|--extended-regexp|--word-regexp|--no-messages|--invert-match|--hidden|--no-ignore|--with-filename|--no-filename) ;;
      --*) return 1 ;;
      -?*) body="${tok#-}"
           # shellcheck disable=SC2053
           [[ $body == *[!$letters]* ]] && return 1
           # shellcheck disable=SC2053
           [[ $body == *[$modes]* ]] && mode=1 ;;
    esac
  done
  [ "$mode" = "1" ]
}

RE_SQ_RUN="^([^']*)'[^']*'(.*)\$"
RE_DOLLAR='\$([A-Za-z_][A-Za-z0-9_:]*|\{|[0-9@*#?!(-])'
unresolved_arg() {
  local t="$1" name
  while [[ $t =~ $RE_SQ_RUN ]]; do t="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; done
  t="${t//\\\$/}"
  t="${t//\$env:USERPROFILE/}"; t="${t//\$\{HOME\}/}"
  while [[ $t =~ $RE_DOLLAR ]]; do
    name="${BASH_REMATCH[1]}"
    [ "$name" = "HOME" ] || return 0
    t="${t/\$HOME/}"
  done
  t="${t,,}"; t="${t//%userprofile%/}"
  [[ $t =~ %[a-z_][a-z0-9_]*% ]]
}

CHECK8_HIT=""
CHECK8_UNRESOLVED=""
CHECK8_SAW_VERB=0
CHECK8_CWD="$PWD"
for seg in "${SEGS[@]}"; do
  if [[ $seg =~ (^|[^\<])\<[[:space:]]*([^[:space:]\<\>]+) ]]; then
    REDIR_TARGET="${BASH_REMATCH[2]}"
    if [ -z "${CHECK8_LIB_LOADED:-}" ] && [ -r "$SECRET_PATHS_LIB" ]; then
      . "$SECRET_PATHS_LIB"
      CHECK8_LIB_LOADED=1
    fi
    if [ "${CHECK8_LIB_LOADED:-}" = "1" ]; then
      check8_token "$REDIR_TARGET" none && break
    fi
  fi
  seg="${seg//</ }"                       # `cat<.env`: input redirect is a read
  effective_words "$seg"
  [ ${#EW[@]} -gt 0 ] || continue
  norm_word "${EW[0]}"; VERB="$NW"
  if [ "$VERB" = "cd" ]; then
    expand_home "${EW[1]:-$HOME}"; HOMEX="${HOMEX//\"/}"; HOMEX="${HOMEX//\'/}"
    case "$HOMEX" in /*|[A-Za-z]:*) CHECK8_CWD="$HOMEX" ;; *) CHECK8_CWD="$CHECK8_CWD/$HOMEX" ;; esac
    continue
  fi
  case "$CHECK8_VERBS$CHECK8_GREP_VERBS$CHECK8_CODE_VERBS" in *" $VERB "*) ;; *) continue ;; esac
  CHECK8_SAW_VERB=1
  if [ -z "${CHECK8_LIB_LOADED:-}" ]; then
    if [ -r "$SECRET_PATHS_LIB" ]; then
      # shellcheck source=secret-paths.sh
      . "$SECRET_PATHS_LIB"
      CHECK8_LIB_LOADED=1
    else
      CHECK8_LIB_LOADED=missing
    fi
  fi
  [ "$CHECK8_LIB_LOADED" = "missing" ] && break

  ARGS=(); skip_next=0
  for tok in "${EW[@]:1}"; do
    if [ "$skip_next" = "1" ]; then skip_next=0; continue; fi
    case "$tok" in
      *'>'*) left="${tok%%>*}"; right="${tok#*>}"; right="${right#>}"
             [[ $left =~ ^[0-9]*$ ]] && left=""
             [ -n "$left" ] && ARGS+=("$left")
             [ -z "$right" ] && skip_next=1
             continue ;;
    esac
    ARGS+=("$tok")
  done

  DIRMODE=none
  case "$CHECK8_CODE_VERBS" in
    *" $VERB "*)
      pieces="${SCRUB//[\"\'(),;+\`[:space:]]/$NL}"
      ARGS=()
      while IFS= read -r tok; do [ -n "$tok" ] && ARGS+=("$tok"); done <<< "$pieces" ;;
  esac
  case "$CHECK8_GREP_VERBS" in
    *" $VERB "*)
      grep_safe "$VERB" "${ARGS[@]}" && continue
      by_opt=0; drop_next=0; KEEP=(); dropped=0
      for tok in "${ARGS[@]}"; do
        if [ "$drop_next" = "1" ]; then drop_next=0; continue; fi
        lt="${tok,,}"
        case "$VERB" in
          select-string|sls)
            case "$lt" in -pat*) by_opt=1; drop_next=1; continue ;; -*) continue ;; esac ;;
          findstr)
            case "$lt" in [-/]c:*) by_opt=1; continue ;; /s|-s) DIRMODE=all; continue ;; [-/]*) continue ;; esac ;;
          *)
            case "$tok" in
              -e*|-f*|--regexp*|--file*) by_opt=1; continue ;;
              --recursive|--dereference-recursive) DIRMODE=all; continue ;;
              --*) continue ;;
              -?*) [[ $tok == *[ef]* ]] && by_opt=1
                   [ "$VERB" != "rg" ] && [[ $tok == *[rR]* ]] && DIRMODE=all
                   continue ;;
            esac ;;
        esac
        KEEP+=("$tok")
      done
      [ "$VERB" = "rg" ] && DIRMODE=visible
      if [ "$by_opt" = "0" ] && [ ${#KEEP[@]} -gt 0 ]; then KEEP=("${KEEP[@]:1}"); fi
      [ "$DIRMODE" != "none" ] && [ ${#KEEP[@]} -eq 0 ] && KEEP=(".")
      ARGS=("${KEEP[@]}") ;;
    *)
      case "$VERB" in
        sed)
          inplace=0; tostd=0
          for tok in "${ARGS[@]}"; do
            case "$tok" in --in-place*|-i*|-[!-]*i*) inplace=1 ;; esac
            case "$tok" in */dev/std*|*/dev/fd*|*/proc/*) tostd=1 ;; esac
          done
          [ "$inplace" = "1" ] && [ "$tostd" = "0" ] && continue ;;
        cut)
          joined=" ${ARGS[*]//[\"\']/} "
          case "$joined" in *" -d= "*|*" -d = "*|*" --delimiter== "*) case "$joined" in *" -f1 "*|*" -f 1 "*|*" --fields=1 "*) continue ;; esac ;; esac ;;
        curl|wget)
          POS=(); takes=0
          for tok in "${ARGS[@]}"; do
            if [ "$takes" = "1" ]; then takes=0; POS+=("$tok"); continue; fi
            case "$tok" in
              -T|--upload-file|-K|--config|-i|--input-file) takes=1 ;;
              --post-file=*|--body-file=*|--input-file=*|--upload-file=*) POS+=("${tok#*=}") ;;
              *@*) case "${tok//[\"\']/}" in @*|*=@*) POS+=("$tok") ;; esac ;;
            esac
          done
          ARGS=("${POS[@]}") ;;
        cp)
          POS=(); tdir=0; takes=0
          for tok in "${ARGS[@]}"; do
            if [ "$takes" = "1" ]; then takes=0; continue; fi
            case "$tok" in -t|--target-directory) tdir=1; takes=1; continue ;; --target-directory=*|-t?*) tdir=1; continue ;; -*) continue ;; esac
            POS+=("$tok")
          done
          [ "$tdir" = "0" ] && [ ${#POS[@]} -gt 1 ] && POS=("${POS[@]:0:$((${#POS[@]}-1))}")
          ARGS=("${POS[@]}") ;;
      esac ;;
  esac

  for tok in "${ARGS[@]}"; do
    check8_token "$tok" "$DIRMODE" && break
    unresolved_arg "$tok" && { CHECK8_UNRESOLVED="$tok"; break; }
  done
  [ -n "$CHECK8_HIT$CHECK8_UNRESOLVED" ] && break
done

if [ "$CHECK8_SAW_VERB" = "1" ] && [ "${CHECK8_LIB_LOADED:-}" = "missing" ]; then
  deny "Blocked: this command reads a file, but the shared secret-path definition ($SECRET_PATHS_LIB) is missing, so the guard cannot tell whether the target holds secrets. Failing closed by design: reinstall secret-paths.sh into the hooks directory"
fi

if [ -n "$CHECK8_UNRESOLVED" ]; then
  deny "Blocked: a read command gets a path from a variable or a command substitution ($CHECK8_UNRESOLVED), so this guard cannot tell which file it reads. Write the path out literally (\$HOME is fine), or use the Read tool"
fi

if [ -n "$CHECK8_HIT" ]; then
  deny "Blocked: this would print the contents of a secret-bearing file ($CHECK8_HIT) into the transcript. Reference the variable name, or probe it without printing the value (grep -c / grep -q). For a folder search, exclude the secret file or use the Grep tool, which skips gitignored files"
fi

exit 0

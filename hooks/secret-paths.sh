#!/usr/bin/env bash
# secret-paths.sh: the one definition of "this file holds a secret". Sourced by
# pre-tool-use-guard.sh and file-io-guard.sh. If it is missing, both fail closed.
# Defines functions and two arrays. Prints only on request, never exits.


# _secret_norm <path>: the name the OS would open. Drops empty and . segments,
# resolves .., and drops :stream suffixes and trailing dots and spaces, which
# Windows ignores. Sets a variable, so callers need no subshell.
_secret_norm() {
  local p="$1" out="" seg first=1 drive="" lead=""
  local -a parts
  case "$p" in /*) lead=/ ;; esac
  IFS=/ read -r -a parts <<< "$p"
  for seg in "${parts[@]}"; do
    if [ $first = 1 ] && [[ $seg =~ ^[a-z]: ]]; then
      drive="${seg:0:2}"; seg="${seg:2}"
    fi
    first=0
    seg="${seg%%:*}"
    if [[ $seg =~ [^.\ ] ]]; then
      while [[ $seg == *[.\ ] ]]; do seg="${seg%?}"; done
    fi
    [ -n "$seg" ] && [ "$seg" != "." ] || continue
    if [ "$seg" = ".." ]; then
      case "$out" in */*) out="${out%/*}" ;; *) out="" ;; esac
      continue
    fi
    out="${out:+$out/}$seg"
  done
  if [ -n "$drive" ]; then _SECRET_NORM="$drive/$out"; else _SECRET_NORM="$lead$out"; fi
}


# is_secret_path <path>: 0 when the path names a secret-bearing file. Matches the
# basename against anchored patterns, so environment.md and keyboard.md stay safe.
is_secret_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  p="${p//\\//}"
  p="${p,,}"
  _secret_norm "$p"; p="$_SECRET_NORM"
  while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  [ -n "$p" ] || return 1

  local base="${p##*/}"

  case "$base" in
    *.example|*.sample|*.template)          return 1 ;;
    *example.env|*sample.env|*template.env) return 1 ;;
    *.pub)                                  return 1 ;;
  esac

  case "$base" in
    .credentials.json) return 0 ;;
    .env|.env.*)       return 0 ;;
    *.env)             return 0 ;;
    *.pem|*.key)       return 0 ;;
    *.p12|*.pfx)       return 0 ;;
    *.asc|*.gpg)       return 0 ;;
    .npmrc|.pgpass)    return 0 ;;
    .git-credentials|.netrc|_netrc) return 0 ;;
    application_default_credentials.json) return 0 ;;
    credentials|credentials.json|.pypirc|*.kdbx) return 0 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*)  return 0 ;;
    *_rsa|*_dsa|*_ecdsa|*_ed25519)          return 0 ;;
  esac

  case "$p" in
    *ssh-key*) return 0 ;;
  esac

  case "/$p" in
    */.aws/credentials|*/.azure/*|*/.config/gcloud/*) return 0 ;;
    */.kube/config|*/.docker/config.json)             return 0 ;;
  esac

  return 1
}


# is_secret_store_dir <path>: 0 for a folder that exists to hold keys.
is_secret_store_dir() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  p="${p//\\//}"; _secret_norm "${p,,}"; p="/$_SECRET_NORM/"
  case "$p" in
    */.ssh/*|*/.gnupg/*|*/.password-store/*) return 0 ;;
    */.aws/*|*/.azure/*|*/.config/gcloud/*)  return 0 ;;
    */.kube/*|*/.docker/*)                   return 0 ;;
  esac
  return 1
}


# expand_braces <word>: brace expansion without eval, capped at 64 results.
expand_braces() {
  local queue=("$1") out=() w pre body post alt n=0
  local re='^(.*)\{([^{}]*,[^{}]*)\}(.*)$'
  while [ ${#queue[@]} -gt 0 ] && [ $n -lt 64 ]; do
    w="${queue[0]}"; queue=("${queue[@]:1}")
    if [[ $w =~ $re ]]; then
      pre="${BASH_REMATCH[1]}"; body="${BASH_REMATCH[2]}"; post="${BASH_REMATCH[3]}"
      while :; do
        alt="${body%%,*}"
        queue+=("$pre$alt$post")
        [ "$alt" = "$body" ] && break
        body="${body#*,}"
      done
    else
      out+=("$w"); n=$((n+1))
    fi
  done
  printf '%s\n' "${out[@]}"
}


# secret_glob_may_match <glob>: could this wildcard name a secret? Judged against
# the sample basenames below, so it cannot drift from is_secret_path.
secret_glob_may_match() {
  local g="${1:-}" e base s
  [ -n "$g" ] || return 1
  g="${g//\\//}"
  while IFS= read -r e; do
    is_secret_store_dir "$e" && return 0
    base="${e##*/}"; base="${base,,}"
    case "$base" in ''|*[!*]*) ;; *) continue ;; esac
    for s in "${SECRET_PATH_SAMPLES[@]}"; do
      s="${s##*/}"
      # shellcheck disable=SC2053
      [[ $s == $base ]] && return 0
    done
  done < <(expand_braces "$g")
  return 1
}


# dir_top_secret <dir> [visible]: first secret file at the top level of <dir>.
# Top level only, for speed. A secret two folders down is a known limit.
dir_top_secret() {
  local d="${1%/}" f restore
  [ -d "$d" ] || return 1
  restore=$(shopt -p nullglob dotglob)
  shopt -s nullglob dotglob
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    if [ "${2:-}" = "visible" ]; then
      case "${f##*/}" in .*) continue ;; esac
    fi
    if is_secret_path "$f"; then eval "$restore"; printf '%s\n' "$f"; return 0; fi
  done
  eval "$restore"
  return 1
}


# Test corpus. Every entry must be denied by both guards (tests/guards-test.sh).
# Add a path here in the same edit that adds a pattern above.
SECRET_PATH_SAMPLES=(
  '.credentials.json'
  '.env'
  '.env.production'
  'stacks/app/secrets.env'
  'certs/server.pem'
  'certs/server.key'
  'certs/client.p12'
  'certs/client.pfx'
  '.npmrc'
  '.pgpass'
  '.ssh/id_rsa'
  '.ssh/id_ed25519'
  '.ssh/work_ed25519'
  'backups/ssh-key-example.key'
  'backup-key.asc'
  '.password-store/some/secret.gpg'
  '.aws/credentials'
  '/c/Users/x/.aws/credentials'
  '.azure/msal_token_cache.json'
  '.config/gcloud/application_default_credentials.json'
  '.config/gcloud/credentials.db'
  'keys/application_default_credentials.json'
  '.kube/config'
  '/c/Users/x/.docker/config.json'
  '.git-credentials'
  '.netrc'
  '_netrc'
  'archive/old-cli/credentials.json'
  'backup/credentials'
  '.pypirc'
  'keepass/vault.kdbx'
  '.env::$DATA'
  '.env:x'
  '.aws/credentials.'
  'certs/server.key...'
  '.aws//credentials'
  '.aws/./credentials'
  '.config/./gcloud/credentials.db'
  '.kube/x/../config'
  '.config/x/../gcloud/credentials.db'
  '/c/Users/x/.docker/y/../config.json'
)


# Paths that must stay readable: ordinary files and lookalikes.
SECRET_PATH_SAFE_SAMPLES=(
  'README.md'
  'package.json'
  '.env.example'
  'src/main.py'
  'docs/environment.md'
  'docs/keyboard.md'
  'sample.env'
  'example.env'
  'config/template.env'
  '.ssh/id_ed25519.pub'
  'src/env.d.ts'
  'alembic/env.py'
  'frontend/.env.local.example'
  '.env.local.example'
  'app/.env.staging.example'
  'docs/aws/credentials.md'
  'infra/aws/config.tf'
  'src/azure/client.ts'
  'scripts/gcloud/deploy.sh'
  'k8s/kube/config.yaml'
  'docker/config.json'
  'docs/git-credentials.md'
  'docs/credentials.md'
  '.config/gcloud/../notes.md'
)

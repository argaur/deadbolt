#!/usr/bin/env bash
# ensure-jq.sh: make `jq` resolvable inside a hook. Source it near the top of any
# hook that needs jq. Claude Code starts hooks with a thinner PATH than your shell.
#
# It never exits, never prints, and never fails the caller. It only extends PATH
# when it can. If jq really is missing, the caller's own check still fires.

__ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  local dir
  for dir in \
    "${HOME:-}/bin" \
    "${HOME:-}/.local/bin" \
    "${HOME:-}/AppData/Local/Microsoft/WinGet/Links" \
    "${HOME:-}"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq*/ \
    /usr/local/bin \
    /opt/homebrew/bin \
    /usr/bin \
    /mingw64/bin \
    "/c/ProgramData/chocolatey/bin"
  do
    [ -d "$dir" ] || continue
    if [ -x "$dir/jq" ] || [ -x "$dir/jq.exe" ]; then
      PATH="$dir:${PATH:-}"
      export PATH
      break
    fi
  done
  return 0
}

__ensure_jq
unset -f __ensure_jq 2>/dev/null || true

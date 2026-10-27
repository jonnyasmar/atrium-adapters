#!/usr/bin/env bash
set -euo pipefail
for name in python3 python py; do
  hash "$name" 2>/dev/null || continue
  interpreter="$name"
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    interpreter="${BASH_CMDS[$name]:-$name}"
    shopt -s nocasematch
    case "$interpreter" in
      */microsoft/windowsapps/*) shopt -u nocasematch; continue ;;
    esac
    shopt -u nocasematch
  fi
  if [ "$name" = py ]; then exec "$interpreter" -3 "$@"; fi
  exec "$interpreter" "$@"
done
echo "${ATRIUM_COPILOT_METHOD:-copilot}: no runnable Python 3 (tried python3, python, py -3)" >&2
exit 3

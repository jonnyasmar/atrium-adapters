#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for OpenCode.
# Contract: see ../../schemas/canonical-event.schema.json
#
# OpenCode stores sessions at:
#   ~/.local/share/opencode/project/<encoded>/storage/session/info/ses_<id>.json
#   ~/.local/share/opencode/project/<encoded>/storage/session/messages/<id>/<msg>.json
#
# Env: ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY).
#   In fixture mode, fixture-session.json + fixture-messages/ subdir.

# Resolve a runnable Python 3 into PYTHON. On Windows `python3` is often the
# Microsoft Store app-execution alias (...\Microsoft\WindowsApps\python3): it
# exists but runs nothing, while python.org and conda installs answer to
# `python` or the `py -3` launcher. Inline rather than in ../shared: sourcing
# that costs two subshells per call on Windows.
find_python() {
  local name path
  for name in python3 python py; do
    hash "$name" 2>/dev/null || continue
    path="$name"
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
      path="${BASH_CMDS[$name]:-$name}"
      shopt -s nocasematch
      case "$path" in
        */microsoft/windowsapps/*)
          shopt -u nocasematch
          continue
          ;;
      esac
      shopt -u nocasematch
    fi
    PYTHON=("$path")
    [ "$name" != py ] || PYTHON+=(-3)
    return 0
  done
  return 1
}

if ! find_python; then
  echo "extract_session: no runnable Python 3 (tried python3, python, py -3)" >&2
  exit 3
fi

if [[ "${1:-}" == "--usage" ]]; then
  shift
  exec "${PYTHON[@]}" "$(dirname "$0")/extract_session_usage.py" --usage "$@"
fi

SESSION_ID=""
CWD=""
DEPTH="standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --cwd)        CWD="$2";        shift 2 ;;
    --depth)      DEPTH="$2";      shift 2 ;;
    *) echo "extract_session: unknown arg $1" >&2; exit 10 ;;
  esac
done

if [[ -z "$SESSION_ID" ]]; then
  echo "extract_session: --session-id required" >&2
  exit 10
fi

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
exec "${PYTHON[@]}" "$SCRIPT_DIR/extract_session.py" \
  --session-id "$SESSION_ID" \
  --adapter opencode \
  --cwd "$CWD" \
  --depth "$DEPTH"

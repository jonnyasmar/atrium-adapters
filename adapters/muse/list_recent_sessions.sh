#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent, directly-resumable Muse Code sessions.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive, sourcePath}, ...]}
#
# Muse stores one directory per session under a date-partitioned root:
#   ~/.local/share/muse/sessions/<YYYY>/<MM>/<DD>/<session-uuid>/session.jsonl
# There is no cwd-encoded path (unlike Claude's project dirs), so the workspace
# has to be read out of each log's metadata record.
#
# Delegated to python3 in ONE process rather than a shell loop: the records are
# JSON, some arrive wrapped in `session_permission_transaction` frames whose
# real payloads live in `children[].record_json` (a JSON string inside JSON),
# and a per-file jq/sed invocation would blow the <50ms adapter budget.
#
# Env: ATRIUM_TEST_MUSE_SESSION_ROOT — overrides the session root (CI fixtures).

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"

# Resolve a runnable Python 3 into PYTHON. On Windows `python3` is often the
# Microsoft Store app-execution alias (...\Microsoft\WindowsApps\python3): it
# exists but runs nothing, while python.org and conda installs answer to
# `python` or the `py -3` launcher. Inline rather than in ../shared: sourcing
# that costs two subshells per call on Windows, on the launcher's path.
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
  echo "list_recent_sessions: no runnable Python 3 (tried python3, python, py -3)" >&2
  echo '{"sessions": []}'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${PYTHON[@]}" "${SCRIPT_DIR}/list_recent_sessions.py" "$CWD"

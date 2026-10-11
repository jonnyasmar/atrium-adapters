#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Cursor Agent.
# Contract: see ../../schemas/canonical-event.schema.json
#
# Cursor stores chats at:
#   ~/.cursor/chats/<md5(realpath(cwd))>/<sessionId>/store.db
# (SQLite database; meta table has hex-encoded JSON in row key='0').
#
# Env: ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY).

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

# Resolve transcript DB. Fixture mode: fixture-session.db.
TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.db" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.db"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  # Production: hash cwd → workspace dir
  WORKSPACE_HASH=$("${PYTHON[@]}" -c "
import hashlib, os, sys
cwd = sys.argv[1]
try:
    resolved = os.path.realpath(cwd)
except OSError:
    resolved = cwd
print(hashlib.md5(resolved.encode('utf-8')).hexdigest())
" "$CWD" 2>/dev/null || true)
  if [[ -n "$WORKSPACE_HASH" ]]; then
    CANDIDATE="${HOME}/.cursor/chats/${WORKSPACE_HASH}/${SESSION_ID}/store.db"
    if [[ -f "$CANDIDATE" ]]; then
      TRANSCRIPT="$CANDIDATE"
    fi
  fi
  # Fallback: cwd → workspace hash is fragile (worktrees, renamed
  # dirs, sessions enumerated from a cwd different from where the
  # user ran cursor). Scan ~/.cursor/chats for any session dir
  # whose name matches.
  if [[ -z "$TRANSCRIPT" ]] && [[ -d "${HOME}/.cursor/chats" ]]; then
    CANDIDATE=$(find "${HOME}/.cursor/chats" -mindepth 3 -maxdepth 3 -type f -name "store.db" -path "*/${SESSION_ID}/*" -print -quit 2>/dev/null || true)
    if [[ -n "$CANDIDATE" ]]; then
      TRANSCRIPT="$CANDIDATE"
    fi
  fi
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: cursor-agent transcript not found for $SESSION_ID" >&2
  exit 1
fi

exec "${PYTHON[@]}" "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter cursor-agent \
  --cwd "$CWD" \
  --depth "$DEPTH"

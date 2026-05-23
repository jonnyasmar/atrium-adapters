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

if ! command -v python3 >/dev/null 2>&1; then
  echo "extract_session: python3 required" >&2
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
  WORKSPACE_HASH=$(python3 -c "
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
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: cursor-agent transcript not found for $SESSION_ID" >&2
  exit 1
fi

exec python3 "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter cursor-agent \
  --cwd "$CWD" \
  --depth "$DEPTH"

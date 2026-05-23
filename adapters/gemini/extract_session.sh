#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Gemini CLI.
# Contract: see ../../schemas/canonical-event.schema.json
#
# Gemini stores sessions at:
#   ~/.gemini/tmp/<project-name>/chats/session-*.json
# Project name resolves via ~/.gemini/projects.json (cwd → name).
#
# Per architecture line 506: Gemini transcript format is unstable.
# On parser failure the script emits ONLY session_start + session_end
# (degraded metadata-only path) and exits 0 — never crashes the runner.
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

# Find transcript. Fixture mode: use fixture-session.json directly.
TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.json" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.json"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  GEMINI_DIR="${HOME}/.gemini"
  PROJECTS_FILE="${GEMINI_DIR}/projects.json"
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    echo "extract_session: gemini projects.json not found: $PROJECTS_FILE" >&2
    exit 1
  fi
  # Resolve project name for CWD (mirror list_recent_sessions.sh heuristic)
  PROJECT_NAME=$(python3 -c "
import json, sys, os
cwd = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
search = cwd
try:
    projects = json.load(open(sys.argv[2])).get('projects', {})
except Exception:
    sys.exit(0)
while True:
    if search in projects:
        print(projects[search])
        sys.exit(0)
    parent = os.path.dirname(search)
    if parent == search:
        break
    search = parent
" "$CWD" "$PROJECTS_FILE" 2>/dev/null || true)
  if [[ -z "$PROJECT_NAME" ]]; then
    echo "extract_session: no gemini project mapping for cwd: $CWD" >&2
    exit 1
  fi
  CANDIDATE="${GEMINI_DIR}/tmp/${PROJECT_NAME}/chats/session-${SESSION_ID}.json"
  if [[ -f "$CANDIDATE" ]]; then
    TRANSCRIPT="$CANDIDATE"
  else
    # Fallback: scan for session-*.json containing our session ID
    TRANSCRIPT=$(find "${GEMINI_DIR}/tmp" -name "session-*${SESSION_ID}*.json" -print -quit 2>/dev/null || true)
  fi
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: session not found: $SESSION_ID" >&2
  exit 1
fi

exec python3 "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter gemini \
  --cwd "$CWD" \
  --depth "$DEPTH"

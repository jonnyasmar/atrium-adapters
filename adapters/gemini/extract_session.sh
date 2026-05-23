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
  # Try the direct path when we have a project mapping, but ALWAYS fall
  # through to the find-scan if it doesn't resolve. The cwd → project
  # mapping is fragile (worktrees, renamed dirs, sessions discovered by
  # the backfill from a different cwd than where gemini ran them) — the
  # find-scan is authoritative and bounded by the GEMINI_DIR/tmp size.
  if [[ -n "$PROJECT_NAME" ]]; then
    CANDIDATE="${GEMINI_DIR}/tmp/${PROJECT_NAME}/chats/session-${SESSION_ID}.json"
    if [[ -f "$CANDIDATE" ]]; then
      TRANSCRIPT="$CANDIDATE"
    fi
  fi
  if [[ -z "$TRANSCRIPT" ]]; then
    # Gemini filenames only carry the first 8 chars of the UUID
    # (e.g. `session-2026-04-20T17-18-f48d75d6.json`) but the full
    # UUID lives in the file's `sessionId` field. list_recent_sessions
    # emits the full UUID; we have to match by prefix here. Then
    # verify by reading the file's sessionId — guards against
    # 8-char-prefix collisions (1 / 2^32 — vanishingly rare but
    # cheap to confirm).
    PREFIX="${SESSION_ID:0:8}"
    while IFS= read -r CANDIDATE_PATH; do
      [[ -z "$CANDIDATE_PATH" ]] && continue
      FILE_SID=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get('sessionId', ''))
except Exception:
    pass
" "$CANDIDATE_PATH" 2>/dev/null || true)
      if [[ "$FILE_SID" == "$SESSION_ID" ]]; then
        TRANSCRIPT="$CANDIDATE_PATH"
        break
      fi
    done < <(find "${GEMINI_DIR}/tmp" -name "session-*${PREFIX}*.json" 2>/dev/null)
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

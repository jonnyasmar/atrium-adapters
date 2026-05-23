#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Codex.
# Contract: see ../../schemas/canonical-event.schema.json
#
# Codex stores rollout files at:
#   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
# First line is {type: "session_meta", payload: {id, cwd, timestamp, ...}}.
# Subsequent lines are OpenAI-shaped {type, role|function_call|..., content, ...}.
#
# Env: ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY — overrides
#      the production ~/.codex/sessions transcript root).

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
  echo "extract_session: python3 required (install python3 on this system)" >&2
  exit 3
fi

SESSIONS_ROOT="${ATRIUM_TEST_TRANSCRIPT_ROOT:-${HOME}/.codex/sessions}"
if [[ ! -d "$SESSIONS_ROOT" ]]; then
  echo "extract_session: codex sessions root not found: $SESSIONS_ROOT" >&2
  exit 1
fi

# Find the rollout file whose session_meta.payload.id matches SESSION_ID.
# In fixture mode, the fixture-session.jsonl directly contains the session.
TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "$SESSIONS_ROOT/fixture-session.jsonl" ]] && [[ -f "$SESSIONS_ROOT/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "$SESSIONS_ROOT/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="$SESSIONS_ROOT/fixture-session.jsonl"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  # Production: walk date-partitioned rollout files, match by session_meta.payload.id
  TRANSCRIPT=$(python3 - "$SESSIONS_ROOT" "$SESSION_ID" <<'PY' 2>/dev/null || true
import glob, json, os, sys
root, session_id = sys.argv[1], sys.argv[2]
for path in sorted(glob.glob(os.path.join(root, "*/*/*/rollout-*.jsonl")), reverse=True):
    try:
        with open(path) as f:
            first = f.readline()
        meta = json.loads(first)
        if meta.get("type") != "session_meta":
            continue
        payload = meta.get("payload")
        if isinstance(payload, str):
            payload = json.loads(payload)
        if isinstance(payload, dict) and payload.get("id") == session_id:
            print(path)
            sys.exit(0)
    except (json.JSONDecodeError, OSError, KeyError):
        continue
PY
)
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: session not found: $SESSION_ID" >&2
  exit 1
fi

exec python3 "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter codex \
  --cwd "$CWD" \
  --depth "$DEPTH"

#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Antigravity (agy).
# Contract: see ../../schemas/canonical-event.schema.json
#
# Antigravity stores per-session transcripts at:
#   ~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl
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

TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.jsonl" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.jsonl"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  AGY_BRAIN="${HOME}/.gemini/antigravity-cli/brain/${SESSION_ID}/.system_generated/logs/transcript.jsonl"
  if [[ -f "$AGY_BRAIN" ]]; then
    TRANSCRIPT="$AGY_BRAIN"
  fi
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: antigravity transcript not found for $SESSION_ID" >&2
  exit 1
fi

exec python3 "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter antigravity \
  --cwd "$CWD" \
  --depth "$DEPTH"

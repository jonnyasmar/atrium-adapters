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

INFO_FILE=""
MESSAGES_DIR=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.json" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    INFO_FILE="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.json"
    MESSAGES_DIR="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-messages"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  DATA_DIR="${HOME}/.local/share/opencode"
  if [[ ! -d "$DATA_DIR" ]]; then
    echo "extract_session: opencode data dir not found: $DATA_DIR" >&2
    exit 1
  fi
  # opencode has shipped two storage layouts; scan both:
  #   1. legacy: data/project/<encoded>/storage/session/info/<sid>.json
  #      + messages/<sid>/<msg>.json
  #   2. newer: data/storage/session_diff/ses_<sid>.json (no per-project)
  # Walk both — first match wins.
  FOUND=$(python3 -c "
import glob, os, sys
data_dir = sys.argv[1]
sid = sys.argv[2]
patterns = [
    os.path.join(data_dir, 'project', '*', 'storage', 'session', 'info', '*.json'),
    os.path.join(data_dir, 'storage', 'session_diff', '*.json'),
    os.path.join(data_dir, 'storage', 'session', 'info', '*.json'),
]
for pattern in patterns:
    for info in glob.glob(pattern):
        base = os.path.splitext(os.path.basename(info))[0]
        if base == sid or base == 'ses_' + sid or base.endswith('_' + sid):
            # messages dir is sibling of info dir for the legacy layout;
            # newer layouts may not have it (best-effort).
            msg_dir = os.path.join(os.path.dirname(os.path.dirname(info)), 'messages', base)
            print(info)
            print(msg_dir if os.path.isdir(msg_dir) else '')
            sys.exit(0)
" "$DATA_DIR" "$SESSION_ID" 2>/dev/null || true)
  if [[ -n "$FOUND" ]]; then
    INFO_FILE=$(echo "$FOUND" | head -1)
    MESSAGES_DIR=$(echo "$FOUND" | tail -1)
  fi
fi

if [[ -z "$INFO_FILE" ]] || [[ ! -f "$INFO_FILE" ]]; then
  echo "extract_session: opencode session info not found: $SESSION_ID" >&2
  exit 1
fi

exec python3 "$(dirname "$0")/extract_session.py" \
  --info "$INFO_FILE" \
  --messages-dir "$MESSAGES_DIR" \
  --session-id "$SESSION_ID" \
  --adapter opencode \
  --cwd "$CWD" \
  --depth "$DEPTH"

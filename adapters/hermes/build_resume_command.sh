#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Hermes session.
# Hermes resume format: hermes chat [--yolo] --resume <session_id>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["hermes", "chat", "--resume", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

YOLO=false
if command -v jq >/dev/null 2>&1; then
  YOLO="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO=false
else
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true'; then
    YOLO=true
  fi
fi

ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

if [ "$YOLO" = "true" ]; then
  echo "{\"command\": [\"hermes\", \"chat\", \"--yolo\", \"--resume\", \"${ESCAPED_SESSION_ID}\"]}"
else
  echo "{\"command\": [\"hermes\", \"chat\", \"--resume\", \"${ESCAPED_SESSION_ID}\"]}"
fi
exit 0

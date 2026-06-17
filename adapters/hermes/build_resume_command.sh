#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Hermes session.
# Routes through launch.sh (registers the pane as a Hermes agent at spawn —
# here with the real resumed session id from argv — then exec's
# `hermes chat --resume <id>`).
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["<dir>/launch.sh", "--resume", "<session_id>"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  echo "{\"command\": [\"${DIR}/launch.sh\", \"--yolo\", \"--resume\", \"${ESCAPED_SESSION_ID}\"]}"
else
  echo "{\"command\": [\"${DIR}/launch.sh\", \"--resume\", \"${ESCAPED_SESSION_ID}\"]}"
fi
exit 0

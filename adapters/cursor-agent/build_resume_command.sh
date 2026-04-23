#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Cursor Agent session.
# Cursor Agent resume format: cursor-agent [--force] [--plan] --resume <chatId>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["cursor-agent", "--resume", "chat-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

YOLO=false
PLAN=false
EXTRA=""
if command -v jq &>/dev/null; then
  YOLO="$(echo "$FLAGS" | jq -r '.yolo // .dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO=false
  PLAN="$(echo "$FLAGS" | jq -r '.plan // false' 2>/dev/null)" || PLAN=false
  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
else
  if echo "$FLAGS" | grep -qE '"yolo"\s*:\s*true|"dangerouslySkipPermissions"\s*:\s*true'; then
    YOLO=true
  fi
  if echo "$FLAGS" | grep -qE '"plan"\s*:\s*true'; then
    PLAN=true
  fi
fi

# Escape session ID for JSON
ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

CMD='["cursor-agent"'
[ "$YOLO" = "true" ] && CMD="${CMD}, \"--force\""
[ "$PLAN" = "true" ] && CMD="${CMD}, \"--plan\""
if [ -n "$EXTRA" ]; then
  for arg in $EXTRA; do
    CMD="${CMD}, \"${arg}\""
  done
fi
CMD="${CMD}, \"--resume\", \"${ESCAPED_SESSION_ID}\"]"

echo "{\"command\": ${CMD}}"
exit 0

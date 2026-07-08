#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Hermes session.
# Hermes resume format: hermes chat [--yolo] --resume <session_id>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["hermes", "chat", ...flags, "--resume", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

YOLO=false
MODEL=""
PROVIDER=""
EXTRA=""
if command -v jq >/dev/null 2>&1; then
  YOLO="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO=false
  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  PROVIDER="$(echo "$FLAGS" | jq -r '.provider // ""' 2>/dev/null)" || PROVIDER=""
  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
else
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true'; then
    YOLO=true
  fi
fi

ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

CMD='["hermes", "chat"'
if [ "$YOLO" = "true" ]; then
  CMD="${CMD}, \"--yolo\""
fi
if [ -n "$MODEL" ]; then
  CMD="${CMD}, \"-m\", \"${MODEL}\""
fi
if [ -n "$PROVIDER" ]; then
  CMD="${CMD}, \"--provider\", \"${PROVIDER}\""
fi
if [ -n "$EXTRA" ]; then
  for arg in $EXTRA; do
    CMD="${CMD}, \"${arg}\""
  done
fi
CMD="${CMD}, \"--resume\", \"${ESCAPED_SESSION_ID}\"]"

echo "{\"command\": ${CMD}}"
exit 0

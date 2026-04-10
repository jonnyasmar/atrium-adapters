#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Gemini CLI session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["gemini", "--resume", "session-id", ...flags]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> <flags_json>}"
FLAGS="${2:-"{}"}"
CMD="[\"gemini\", \"--resume\", \"${SESSION_ID}\""

if command -v jq &>/dev/null; then
  YOLO="$(echo "$FLAGS" | jq -r '.yolo // false' 2>/dev/null)" || YOLO="false"
  if [ "$YOLO" = "true" ]; then
    CMD="${CMD}, \"--approval-mode\", \"yolo\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

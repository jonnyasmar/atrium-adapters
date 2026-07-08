#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Grok session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["grok", ...flags, "-r", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

ALWAYS_APPROVE=false
MODEL=""
EFFORT=""
EXTRA=""
if command -v jq &>/dev/null; then
  ALWAYS_APPROVE="$(echo "$FLAGS" | jq -r '.alwaysApprove // false' 2>/dev/null)" || ALWAYS_APPROVE=false
  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
else
  if echo "$FLAGS" | grep -qE '"alwaysApprove"\s*:\s*true'; then
    ALWAYS_APPROVE=true
  fi
fi

ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

CMD='["grok"'
if [ "$ALWAYS_APPROVE" = "true" ]; then
  CMD="${CMD}, \"--always-approve\""
fi
if [ -n "$MODEL" ]; then
  CMD="${CMD}, \"--model\", \"${MODEL}\""
fi
if [ -n "$EFFORT" ]; then
  CMD="${CMD}, \"--reasoning-effort\", \"${EFFORT}\""
fi
if [ -n "$EXTRA" ]; then
  for arg in $EXTRA; do
    CMD="${CMD}, \"${arg}\""
  done
fi
CMD="${CMD}, \"-r\", \"${ESCAPED_SESSION_ID}\"]"

echo "{\"command\": ${CMD}}"
exit 0

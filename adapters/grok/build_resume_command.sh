#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Grok session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["grok", "-r", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

ALWAYS_APPROVE=false
if command -v jq &>/dev/null; then
  ALWAYS_APPROVE="$(echo "$FLAGS" | jq -r '.alwaysApprove // false' 2>/dev/null)" || ALWAYS_APPROVE=false
else
  if echo "$FLAGS" | grep -qE '"alwaysApprove"\s*:\s*true'; then
    ALWAYS_APPROVE=true
  fi
fi

ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

if [ "$ALWAYS_APPROVE" = "true" ]; then
  echo "{\"command\": [\"grok\", \"--always-approve\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
else
  echo "{\"command\": [\"grok\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
fi
exit 0

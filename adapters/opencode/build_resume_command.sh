#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume an OpenCode session.
# OpenCode resume format: opencode --session <session_id>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["opencode", "--session", "session-id", ...flags]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
CMD="[\"opencode\", \"--session\", \"${ESCAPED_SESSION_ID}\""

if command -v jq &>/dev/null; then
  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"--model\", \"${MODEL}\""
  fi

  AGENT="$(echo "$FLAGS" | jq -r '.agent // ""' 2>/dev/null)" || AGENT=""
  if [ -n "$AGENT" ]; then
    CMD="${CMD}, \"--agent\", \"${AGENT}\""
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

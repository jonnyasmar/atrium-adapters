#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Claude Code session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["claude", "--resume", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

# Parse dangerouslySkipPermissions from flags JSON
SKIP_PERMISSIONS=false
if command -v jq &>/dev/null; then
  SKIP_PERMISSIONS="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // .dangerous_skip_permissions // false' 2>/dev/null)" || SKIP_PERMISSIONS=false
else
  # Fallback: grep for the key
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true|"dangerous_skip_permissions"\s*:\s*true'; then
    SKIP_PERMISSIONS=true
  fi
fi

# Escape session ID for JSON output
ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

if [ "$SKIP_PERMISSIONS" = "true" ]; then
  echo "{\"command\": [\"claude\", \"--dangerously-skip-permissions\", \"--resume\", \"${ESCAPED_SESSION_ID}\"]}"
else
  echo "{\"command\": [\"claude\", \"--resume\", \"${ESCAPED_SESSION_ID}\"]}"
fi
exit 0

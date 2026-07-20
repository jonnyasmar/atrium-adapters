#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Claude Code session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["DISABLE_AUTOUPDATER=1", "claude", ...flags, "--resume", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

# JSON-escape a raw string for embedding in the command array.
json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

CMD='["DISABLE_AUTOUPDATER=1", "claude"'

if command -v jq &>/dev/null; then
  SKIP="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // .dangerous_skip_permissions // false' 2>/dev/null)" || SKIP=false
  if [ "$SKIP" = "true" ]; then
    CMD="${CMD}, \"--dangerously-skip-permissions\""
  fi

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"--model\", \"$(json_escape "$MODEL")\""
  fi

  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  if [ -n "$EFFORT" ]; then
    CMD="${CMD}, \"--effort\", \"$(json_escape "$EFFORT")\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"$(json_escape "$arg")\""
    done
  fi
else
  # Fallback: grep for the key (skip-permissions only, mirroring launch script)
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true|"dangerous_skip_permissions"\s*:\s*true'; then
    CMD="${CMD}, \"--dangerously-skip-permissions\""
  fi
fi

CMD="${CMD}, \"--resume\", \"$(json_escape "$SESSION_ID")\"]"
echo "{\"command\": ${CMD}}"
exit 0

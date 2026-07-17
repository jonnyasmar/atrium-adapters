#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Codex session.
# Codex resume format: codex [--dangerously-bypass-approvals-and-sandbox] resume <session_id>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["codex", ...flags, "resume", "session-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

CMD='["codex"'

SKIP_PERMISSIONS=false
if command -v jq &>/dev/null; then
  SKIP_PERMISSIONS="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // .dangerous_skip_permissions // false' 2>/dev/null)" || SKIP_PERMISSIONS=false
  if [ "$SKIP_PERMISSIONS" = "true" ]; then
    CMD="${CMD}, \"--dangerously-bypass-approvals-and-sandbox\""
  fi

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"-m\", \"$(json_escape "$MODEL")\""
  fi

  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  if [ -n "$EFFORT" ]; then
    CMD="${CMD}, \"-c\", \"model_reasoning_effort=\\\"$(json_escape "$EFFORT")\\\"\""
  fi

  FAST="$(echo "$FLAGS" | jq -r '.fast // false' 2>/dev/null)" || FAST="false"
  if [ "$FAST" = "true" ]; then
    CMD="${CMD}, \"--enable\", \"fast_mode\", \"-c\", \"service_tier=\\\"fast\\\"\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"$(json_escape "$arg")\""
    done
  fi
else
  # Fallback: grep for the key
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true|"dangerous_skip_permissions"\s*:\s*true'; then
    SKIP_PERMISSIONS=true
  fi
  if [ "$SKIP_PERMISSIONS" = "true" ]; then
    CMD="${CMD}, \"--dangerously-bypass-approvals-and-sandbox\""
  fi
fi

CMD="${CMD}, \"resume\", \"$(json_escape "$SESSION_ID")\"]"
echo "{\"command\": ${CMD}}"
exit 0

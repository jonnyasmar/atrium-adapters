#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Cursor Agent session.
# Cursor Agent resume format: cursor-agent --disable-auto-update [flags] --resume <chatId>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["cursor-agent", "--disable-auto-update", ..., "--resume", "chat-id"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

YOLO=false
AUTO_REVIEW=false
PLAN=false
APPROVE_MCPS=false
TRUST=false
SANDBOX=""
MODEL=""
EXTRA=""
if command -v jq &>/dev/null; then
  YOLO="$(echo "$FLAGS" | jq -r '.yolo // .dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO=false
  AUTO_REVIEW="$(echo "$FLAGS" | jq -r '.autoReview // false' 2>/dev/null)" || AUTO_REVIEW=false
  PLAN="$(echo "$FLAGS" | jq -r '.plan // false' 2>/dev/null)" || PLAN=false
  APPROVE_MCPS="$(echo "$FLAGS" | jq -r '.approveMcps // false' 2>/dev/null)" || APPROVE_MCPS=false
  TRUST="$(echo "$FLAGS" | jq -r '.trust // false' 2>/dev/null)" || TRUST=false
  SANDBOX="$(echo "$FLAGS" | jq -r '.sandbox // ""' 2>/dev/null)" || SANDBOX=""
  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  PERM_MODE="$(echo "$FLAGS" | jq -r '.permissionMode // ""' 2>/dev/null)" || PERM_MODE=""
  if [ "$PERM_MODE" = "plan" ]; then PLAN=true; fi
  if [ "$PERM_MODE" = "auto" ] || [ "$PERM_MODE" = "acceptEdits" ]; then AUTO_REVIEW=true; fi
  if [ "$PERM_MODE" = "yolo" ] || [ "$PERM_MODE" = "bypassPermissions" ]; then YOLO=true; fi
else
  if echo "$FLAGS" | grep -qE '"yolo"\s*:\s*true|"dangerouslySkipPermissions"\s*:\s*true'; then
    YOLO=true
  fi
  if echo "$FLAGS" | grep -qE '"autoReview"\s*:\s*true'; then
    AUTO_REVIEW=true
  fi
  if echo "$FLAGS" | grep -qE '"plan"\s*:\s*true'; then
    PLAN=true
  fi
fi

# Escape session ID for JSON
ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

CMD='["cursor-agent", "--disable-auto-update"'
[ "$YOLO" = "true" ] && CMD="${CMD}, \"--force\""
if [ "$AUTO_REVIEW" = "true" ] && [ "$YOLO" != "true" ]; then
  CMD="${CMD}, \"--auto-review\""
fi
[ "$PLAN" = "true" ] && CMD="${CMD}, \"--plan\""
[ "$APPROVE_MCPS" = "true" ] && CMD="${CMD}, \"--approve-mcps\""
[ "$TRUST" = "true" ] && CMD="${CMD}, \"--trust\""
if [ -n "${SANDBOX:-}" ]; then
  CMD="${CMD}, \"--sandbox\", \"${SANDBOX}\""
fi
if [ -n "${MODEL:-}" ]; then
  MODEL_ESC="$(printf '%s' "$MODEL" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  CMD="${CMD}, \"--model\", \"${MODEL_ESC}\""
fi
if [ -n "$EXTRA" ]; then
  for arg in $EXTRA; do
    ARG_ESC="$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    CMD="${CMD}, \"${ARG_ESC}\""
  done
fi
CMD="${CMD}, \"--resume\", \"${ESCAPED_SESSION_ID}\"]"

echo "{\"command\": ${CMD}}"
exit 0

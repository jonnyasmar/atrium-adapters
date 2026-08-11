#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Cursor Agent.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["cursor-agent", "--disable-auto-update", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["cursor-agent", "--disable-auto-update"'

if command -v jq &>/dev/null; then
  YOLO="$(echo "$FLAGS" | jq -r '.yolo // .dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO="false"
  if [ "$YOLO" = "true" ]; then
    CMD="${CMD}, \"--force\""
  fi

  AUTO_REVIEW="$(echo "$FLAGS" | jq -r '.autoReview // false' 2>/dev/null)" || AUTO_REVIEW="false"
  # permissionMode from atrium chat/launcher may also request auto
  PERM_MODE="$(echo "$FLAGS" | jq -r '.permissionMode // ""' 2>/dev/null)" || PERM_MODE=""
  if [ "$AUTO_REVIEW" = "true" ] || [ "$PERM_MODE" = "auto" ] || [ "$PERM_MODE" = "acceptEdits" ]; then
    # Don't stack auto-review on top of full yolo
    if [ "$YOLO" != "true" ]; then
      CMD="${CMD}, \"--auto-review\""
    fi
  fi

  PLAN="$(echo "$FLAGS" | jq -r '.plan // false' 2>/dev/null)" || PLAN="false"
  if [ "$PLAN" = "true" ] || [ "$PERM_MODE" = "plan" ]; then
    CMD="${CMD}, \"--plan\""
  fi

  APPROVE_MCPS="$(echo "$FLAGS" | jq -r '.approveMcps // false' 2>/dev/null)" || APPROVE_MCPS="false"
  if [ "$APPROVE_MCPS" = "true" ]; then
    CMD="${CMD}, \"--approve-mcps\""
  fi

  TRUST="$(echo "$FLAGS" | jq -r '.trust // false' 2>/dev/null)" || TRUST="false"
  if [ "$TRUST" = "true" ]; then
    CMD="${CMD}, \"--trust\""
  fi

  SANDBOX="$(echo "$FLAGS" | jq -r '.sandbox // ""' 2>/dev/null)" || SANDBOX=""
  if [ -n "$SANDBOX" ]; then
    CMD="${CMD}, \"--sandbox\", \"${SANDBOX}\""
  fi

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    # Escape model for JSON string
    MODEL_ESC="$(printf '%s' "$MODEL" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    CMD="${CMD}, \"--model\", \"${MODEL_ESC}\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      ARG_ESC="$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      CMD="${CMD}, \"${ARG_ESC}\""
    done
  fi
else
  if echo "$FLAGS" | grep -qE '"yolo"\s*:\s*true|"dangerouslySkipPermissions"\s*:\s*true'; then
    CMD="${CMD}, \"--force\""
  elif echo "$FLAGS" | grep -qE '"autoReview"\s*:\s*true'; then
    CMD="${CMD}, \"--auto-review\""
  fi
  if echo "$FLAGS" | grep -qE '"plan"\s*:\s*true'; then
    CMD="${CMD}, \"--plan\""
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Cursor Agent.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["cursor-agent", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["cursor-agent"'

if command -v jq &>/dev/null; then
  YOLO="$(echo "$FLAGS" | jq -r '.yolo // .dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO="false"
  if [ "$YOLO" = "true" ]; then
    CMD="${CMD}, \"--force\""
  fi

  PLAN="$(echo "$FLAGS" | jq -r '.plan // false' 2>/dev/null)" || PLAN="false"
  if [ "$PLAN" = "true" ]; then
    CMD="${CMD}, \"--plan\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
else
  if echo "$FLAGS" | grep -qE '"yolo"\s*:\s*true|"dangerouslySkipPermissions"\s*:\s*true'; then
    CMD="${CMD}, \"--force\""
  fi
  if echo "$FLAGS" | grep -qE '"plan"\s*:\s*true'; then
    CMD="${CMD}, \"--plan\""
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

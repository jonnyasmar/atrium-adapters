#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Hermes.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["hermes", "chat", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["hermes", "chat"'

if command -v jq >/dev/null 2>&1; then
  YOLO="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || YOLO="false"
  [ "$YOLO" = "true" ] && CMD="${CMD}, \"--yolo\""

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  [ -n "$MODEL" ] && CMD="${CMD}, \"-m\", \"${MODEL}\""

  PROVIDER="$(echo "$FLAGS" | jq -r '.provider // ""' 2>/dev/null)" || PROVIDER=""
  [ -n "$PROVIDER" ] && CMD="${CMD}, \"--provider\", \"${PROVIDER}\""

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
else
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true'; then
    CMD="${CMD}, \"--yolo\""
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

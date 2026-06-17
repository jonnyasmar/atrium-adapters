#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Hermes.
# Routes through launch.sh (registers the pane as a Hermes agent at spawn, then
# exec's `hermes chat <flags>` — Hermes itself fires no hook until the first
# message, so without this the activity card wouldn't appear until you type).
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["<dir>/launch.sh", ...flags]}

FLAGS="${1:-"{}"}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="[\"${DIR}/launch.sh\""

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

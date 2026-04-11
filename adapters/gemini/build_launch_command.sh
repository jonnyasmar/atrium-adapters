#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Gemini CLI.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["gemini", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["gemini"'

if command -v jq &>/dev/null; then
  YOLO="$(echo "$FLAGS" | jq -r '.yolo // false' 2>/dev/null)" || YOLO="false"
  if [ "$YOLO" = "true" ]; then
    CMD="${CMD}, \"--yolo\""
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

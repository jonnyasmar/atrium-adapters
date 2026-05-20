#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Antigravity CLI (agy).
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["agy", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["agy"'

if command -v jq &>/dev/null; then
  SKIP="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || SKIP="false"
  if [ "$SKIP" = "true" ]; then
    CMD="${CMD}, \"--dangerously-skip-permissions\""
  fi

  SANDBOX="$(echo "$FLAGS" | jq -r '.sandbox // false' 2>/dev/null)" || SANDBOX="false"
  if [ "$SANDBOX" = "true" ]; then
    CMD="${CMD}, \"--sandbox\""
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

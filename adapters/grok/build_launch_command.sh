#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Grok.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["grok", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["grok"'

if command -v jq &>/dev/null; then
  APPROVE="$(echo "$FLAGS" | jq -r '.alwaysApprove // false' 2>/dev/null)" || APPROVE="false"
  if [ "$APPROVE" = "true" ]; then
    CMD="${CMD}, \"--always-approve\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
else
  if echo "$FLAGS" | grep -qE '"alwaysApprove"\s*:\s*true'; then
    CMD="${CMD}, \"--always-approve\""
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

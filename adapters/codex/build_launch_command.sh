#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Codex.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["codex", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["codex"'

if command -v jq &>/dev/null; then
  SKIP="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || SKIP="false"
  if [ "$SKIP" = "true" ]; then
    CMD="${CMD}, \"--dangerously-bypass-approvals-and-sandbox\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
else
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true'; then
    CMD="${CMD}, \"--dangerously-bypass-approvals-and-sandbox\""
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

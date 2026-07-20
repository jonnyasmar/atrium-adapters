#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Pi coding agent.
# Pi auto-creates a new session when launched with no flags; cwd is
# inferred. Session/tool lifecycle is bridged via the TS extension at
# ~/.pi/agent/extensions/atrium.ts (installed by hooks.sh).
#
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["PI_SKIP_VERSION_CHECK=1", "pi", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["PI_SKIP_VERSION_CHECK=1", "pi"'

if command -v jq &>/dev/null; then
  PROVIDER="$(echo "$FLAGS" | jq -r '.provider // ""' 2>/dev/null)" || PROVIDER=""
  if [ -n "$PROVIDER" ]; then
    CMD="${CMD}, \"--provider\", \"${PROVIDER}\""
  fi

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"--model\", \"${MODEL}\""
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

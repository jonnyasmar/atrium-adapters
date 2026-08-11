#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Factory Droid.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "DROID_DISABLE_AUTO_UPDATE=true", "FACTORY_DROID_AUTO_UPDATE_ENABLED=false", "droid", "exec", "--output-format", "acp", ...flags]}
#
# Note: droid's JSON-RPC mode validates -m/--model but session settings come
# from JSON-RPC requests (session/set_model). The flag is still passed to
# mirror the other ACP adapters; the authoritative model change happens over
# the ACP transport once the chat pane is open.

FLAGS="${1:-"{}"}"
CMD='["env", "DROID_DISABLE_AUTO_UPDATE=true", "FACTORY_DROID_AUTO_UPDATE_ENABLED=false", "droid", "exec", "--output-format", "acp"'

if command -v jq &>/dev/null; then
  RIGHT="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || RIGHT=""
  if [ -n "$RIGHT" ]; then
    CMD="${CMD}, \"--model\", \"${RIGHT}\""
  fi

  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  if [ -n "$EFFORT" ]; then
    CMD="${CMD}, \"--reasoning-effort\", \"${EFFORT}\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"${arg}\""
    done
  fi
fi

CMD="${CMD}]"
printf '{"command": %s}\n' "$CMD"
exit 0

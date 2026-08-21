#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch OpenCode.
# OpenCode treats the first positional arg as the project path, defaulting
# to cwd when omitted. Atrium always launches from the pane's cwd, so we
# don't pass it explicitly — opencode infers it from process.cwd().
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode", ...flags]}

FLAGS="${1:-"{}"}"
CMD='["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode"'

if command -v jq &>/dev/null; then
  # Auto mode: auto-approve permission requests not explicitly denied
  # (explicit "deny" rules still enforced). permissionMode=auto covers
  # atrium chat/launcher flows that request the mode by name.
  AUTO="$(echo "$FLAGS" | jq -r '.autoApprove // false' 2>/dev/null)" || AUTO="false"
  PERM_MODE="$(echo "$FLAGS" | jq -r '.permissionMode // ""' 2>/dev/null)" || PERM_MODE=""
  if [ "$AUTO" = "true" ] || [ "$PERM_MODE" = "auto" ]; then
    CMD="${CMD}, \"--auto\""
  fi

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"--model\", \"${MODEL}\""
  fi

  AGENT="$(echo "$FLAGS" | jq -r '.agent // ""' 2>/dev/null)" || AGENT=""
  if [ -n "$AGENT" ]; then
    CMD="${CMD}, \"--agent\", \"${AGENT}\""
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

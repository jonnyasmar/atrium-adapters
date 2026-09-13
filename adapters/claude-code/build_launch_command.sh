#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Claude Code.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "DISABLE_AUTOUPDATER=1", "claude", ...flags]}

FLAGS="${1:-"{}"}"
SKIP="false"

# JSON-escape a raw string for embedding in the command array.
json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if command -v jq &>/dev/null; then
  SKIP="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || SKIP="false"
else
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true'; then
    SKIP="true"
  fi
fi

BROWSER_PATH="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/claude-code/open_browser.sh"
CMD="[\"env\", \"DISABLE_AUTOUPDATER=1\", \"BROWSER=$(json_escape "$BROWSER_PATH")\""
IS_ROOT="false"
if [ "$SKIP" = "true" ] && [ "$(id -u)" = "0" ]; then
  IS_ROOT="true"
  # Claude refuses every native bypass entry point under uid 0. Keep the
  # selected YOLO behavior through our PermissionRequest hook instead.
  CMD="${CMD}, \"ATRIUM_CLAUDE_ROOT_BYPASS_PERMISSIONS=1\""
fi
CMD="${CMD}, \"claude\""

if [ "$SKIP" = "true" ]; then
  if [ "$IS_ROOT" = "true" ]; then
    CMD="${CMD}, \"--permission-mode\", \"acceptEdits\""
  else
    CMD="${CMD}, \"--dangerously-skip-permissions\""
  fi
fi

if command -v jq &>/dev/null; then
  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  if [ -n "$MODEL" ]; then
    CMD="${CMD}, \"--model\", \"${MODEL}\""
  fi

  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  if [ -n "$EFFORT" ]; then
    CMD="${CMD}, \"--effort\", \"${EFFORT}\""
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

#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Claude Code.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "DISABLE_AUTOUPDATER=1", "claude", ...flags]}

FLAGS="${1:-"{}"}"
SKIP="false"

# JSON-escape a raw string for embedding in the command array. Prefer a real
# JSON encoder so controls (\n/\t) cannot break the argv JSON (ATR-2100).
json_escape() {
  if command -v jq &>/dev/null; then
    # --arg keeps embedded newlines intact; strip the outer JSON quotes.
    jq -n --arg s "$1" '$s' | sed 's/^"//; s/"$//'
  elif command -v python3 &>/dev/null; then
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1])[1:-1])' "$1"
  else
    case "$1" in
      *$'\n'* | *$'\r'* | *$'\t'*)
        echo "json_escape: control characters require jq or python3" >&2
        return 1
        ;;
    esac
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  fi
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
    # Always escape — a raw model string can break out of the JSON argv
    # array and inject flags (ATR-2096).
    CMD="${CMD}, \"--model\", \"$(json_escape "$MODEL")\""
  fi

  EFFORT="$(echo "$FLAGS" | jq -r '.effort // ""' 2>/dev/null)" || EFFORT=""
  if [ -n "$EFFORT" ]; then
    CMD="${CMD}, \"--effort\", \"$(json_escape "$EFFORT")\""
  fi

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      CMD="${CMD}, \"$(json_escape "$arg")\""
    done
  fi
fi

CMD="${CMD}]"
echo "{\"command\": ${CMD}}"
exit 0

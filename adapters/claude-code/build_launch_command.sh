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

# Windows (Git Bash host): atrium joins this argv with spaces and TYPES it into
# the pane shell, which on Windows is PowerShell by default (pwsh → powershell).
# `env` is a coreutils binary, not a PowerShell/cmd command, so the macOS/Linux
# `env VAR=v claude` prefix is a hard launch failure there:
#   PS> env DISABLE_AUTOUPDATER=1 claude
#   The term 'env' is not recognized as the name of a cmdlet...
# The bare binary is the only spelling valid in every pane shell atrium offers
# (pwsh, powershell, cmd, Git Bash), so Windows emits `claude` alone. Both env
# vars are Unix-only anyway: BROWSER points at open_browser.sh, a `.sh` that no
# Win32 CreateProcess can exec, and DISABLE_AUTOUPDATER can be set per-adapter
# from atrium's launcher env settings (delivered via the pane-env file).
IS_WINDOWS="false"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS="true" ;;
esac

IS_ROOT="false"
if [ "$IS_WINDOWS" = "true" ]; then
  CMD='["claude"'
else
  BROWSER_PATH="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/claude-code/open_browser.sh"
  CMD="[\"env\", \"DISABLE_AUTOUPDATER=1\", \"BROWSER=$(json_escape "$BROWSER_PATH")\""
  if [ "$SKIP" = "true" ] && [ "$(id -u)" = "0" ]; then
    IS_ROOT="true"
    # Claude refuses every native bypass entry point under uid 0. Keep the
    # selected YOLO behavior through our PermissionRequest hook instead.
    CMD="${CMD}, \"ATRIUM_CLAUDE_ROOT_BYPASS_PERMISSIONS=1\""
  fi
  CMD="${CMD}, \"claude\""
fi

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

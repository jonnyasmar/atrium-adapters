#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Antigravity CLI (agy).
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "AGY_CLI_DISABLE_AUTO_UPDATE=true", "agy", ...flags]}

FLAGS="${1:-"{}"}"

# Windows (Git Bash host): atrium joins this argv with spaces and TYPES it into
# the pane shell, which on Windows is PowerShell by default. `env` is a
# coreutils binary, not a PowerShell cmdlet — PS answers "The term 'env' is not
# recognized" — and a bare `VAR=v` prefix is not PowerShell syntax either, so
# both spellings are hard launch failures. The bare binary is the only form
# valid in every pane shell atrium offers (pwsh, powershell, cmd, Git Bash).
# AGY_CLI_DISABLE_AUTO_UPDATE stays reachable on Windows through atrium's
# per-adapter launcher env settings, which are delivered with the pane env.
IS_WINDOWS="false"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS="true" ;;
esac

if [ "$IS_WINDOWS" = "true" ]; then
  CMD='["agy"'
else
  CMD='["env", "AGY_CLI_DISABLE_AUTO_UPDATE=true", "agy"'
fi

if command -v jq &>/dev/null; then
  SKIP="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // false' 2>/dev/null)" || SKIP="false"
  if [ "$SKIP" = "true" ]; then
    CMD="${CMD}, \"--dangerously-skip-permissions\""
  fi

  SANDBOX="$(echo "$FLAGS" | jq -r '.sandbox // false' 2>/dev/null)" || SANDBOX="false"
  if [ "$SANDBOX" = "true" ]; then
    CMD="${CMD}, \"--sandbox\""
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

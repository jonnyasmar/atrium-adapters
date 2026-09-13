#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Pi coding agent.
# Pi auto-creates a new session when launched with no flags; cwd is
# inferred. Session/tool lifecycle is bridged via the TS extension at
# ~/.pi/agent/extensions/atrium.ts (installed by hooks.sh).
#
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "PI_SKIP_VERSION_CHECK=1", "pi", ...flags]}

FLAGS="${1:-"{}"}"

# Windows (Git Bash host): atrium joins this argv with spaces and TYPES it into
# the pane shell, which on Windows is PowerShell by default. `env` is a
# coreutils binary, not a PowerShell cmdlet — PS answers "The term 'env' is not
# recognized" — and a bare `VAR=v` prefix is not PowerShell syntax either, so
# both spellings are hard launch failures. The bare binary is the only form
# valid in every pane shell atrium offers (pwsh, powershell, cmd, Git Bash).
# PI_SKIP_VERSION_CHECK stays reachable on Windows through atrium's
# per-adapter launcher env settings, which are delivered with the pane env.
IS_WINDOWS="false"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS="true" ;;
esac

if [ "$IS_WINDOWS" = "true" ]; then
  CMD='["pi"'
else
  CMD='["env", "PI_SKIP_VERSION_CHECK=1", "pi"'
fi

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

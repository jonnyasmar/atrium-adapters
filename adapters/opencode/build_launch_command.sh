#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch OpenCode.
# OpenCode treats the first positional arg as the project path, defaulting
# to cwd when omitted. Atrium always launches from the pane's cwd, so we
# don't pass it explicitly — opencode infers it from process.cwd().
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode", ...flags]}

FLAGS="${1:-"{}"}"

# Windows (Git Bash host): atrium joins this argv with spaces and TYPES it into
# the pane shell, which on Windows is PowerShell by default. `env` is a
# coreutils binary, not a PowerShell cmdlet — PS answers "The term 'env' is not
# recognized" — and a bare `VAR=v` prefix is not PowerShell syntax either, so
# both spellings are hard launch failures. The bare binary is the only form
# valid in every pane shell atrium offers (pwsh, powershell, cmd, Git Bash).
# OPENCODE_DISABLE_AUTOUPDATE stays reachable on Windows through atrium's
# per-adapter launcher env settings, which are delivered with the pane env.
IS_WINDOWS="false"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS="true" ;;
esac

if [ "$IS_WINDOWS" = "true" ]; then
  CMD='["opencode"'
else
  CMD='["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode"'
fi

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

#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume an Antigravity session.
# agy uses `--conversation <id>` (not `--resume`); `--continue`/`-c` is reserved
# for "latest conversation" without an explicit ID.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["env", "AGY_CLI_DISABLE_AUTO_UPDATE=true", "agy", "--conversation", "session-id", ...flags]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> <flags_json>}"
FLAGS="${2:-"{}"}"
ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

# Windows: this argv is typed into a PowerShell pane, where `env` is not a
# command and a bare `VAR=v` prefix is not valid syntax — so Windows starts at
# the bare binary. Same arm as build_launch_command.sh; see the comment there.
IS_WINDOWS="false"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS="true" ;;
esac

if [ "$IS_WINDOWS" = "true" ]; then
  CMD="[\"agy\", \"--conversation\", \"${ESCAPED_SESSION_ID}\""
else
  CMD="[\"AGY_CLI_DISABLE_AUTO_UPDATE=true\", \"agy\", \"--conversation\", \"${ESCAPED_SESSION_ID}\""
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

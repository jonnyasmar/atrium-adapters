#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Pi session.
# Pi accepts an explicit session ID via `--session <id>`. (`pi -c` resumes
# the latest, `pi -r` opens a picker — neither is what atrium wants when
# the user clicks a specific session card.) Lifecycle hooks are bridged
# via the TS extension at ~/.pi/agent/extensions/atrium.ts.
#
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["env", "PI_SKIP_VERSION_CHECK=1", "pi", "--session", "session-id", ...flags]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

if [[ "$SESSION_ID" =~ _([[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12})$ ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
fi

ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"

# Windows: this argv is typed into a PowerShell pane, where `env` is not a
# command and a bare `VAR=v` prefix is not valid syntax — so Windows starts at
# the bare binary. Same arm as build_launch_command.sh; see the comment there.
IS_WINDOWS="false"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS="true" ;;
esac

if [ "$IS_WINDOWS" = "true" ]; then
  CMD="[\"pi\", \"--session\", \"${ESCAPED_SESSION_ID}\""
else
  CMD="[\"PI_SKIP_VERSION_CHECK=1\", \"pi\", \"--session\", \"${ESCAPED_SESSION_ID}\""
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

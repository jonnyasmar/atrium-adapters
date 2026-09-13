#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume an Omp session.
# Omp accepts a session ID via `--resume <id>` (`omp -c` resumes
# the latest, bare `omp -r` opens a picker — neither is what atrium wants when
# the user clicks a specific session card.) Lifecycle hooks are bridged
# via the TS extension at ~/.omp/agent/extensions/atrium.ts.
#
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["env", "DISABLE_SELF_UPDATE=1", "omp", "--resume", "session-id", ...flags]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"
ESCAPED_SESSION_ID="$(echo "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
CMD="[\"DISABLE_SELF_UPDATE=1\", \"omp\", \"--resume\", \"${ESCAPED_SESSION_ID}\""

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

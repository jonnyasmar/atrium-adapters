#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Grok session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["<wrapper>", ...flags, "-r", "session-id"]}
#
# Same wrapper as launch — see grok-with-atrium-rules.sh / build_launch_command.sh
# for why rules must not appear as multi-line argv tokens.

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/grok-with-atrium-rules.sh"

if ! command -v jq &>/dev/null; then
  ESCAPED_SESSION_ID="$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  if [ -f "$WRAPPER" ]; then
    ESCAPED_WRAPPER="$(printf '%s' "$WRAPPER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    echo "{\"command\": [\"${ESCAPED_WRAPPER}\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
  else
    echo "{\"command\": [\"grok\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
  fi
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq empty 2>/dev/null; then
  FLAGS='{}'
fi

jq -n \
  --arg wrapper "$WRAPPER" \
  --argjson flags "$FLAGS" \
  --arg session "$SESSION_ID" \
  '{
    command:
      [$wrapper]
      + (if $flags.alwaysApprove == true then ["--always-approve"] else [] end)
      + (if (($flags.model // "") | length) > 0 then ["--model", $flags.model] else [] end)
      + (if (($flags.effort // "") | length) > 0 then ["--reasoning-effort", $flags.effort] else [] end)
      + (
          if (($flags.extraArgs // "") | length) > 0
          then ($flags.extraArgs | split(" ") | map(select(length > 0)))
          else []
          end
        )
      + ["-r", $session]
  }'
exit 0

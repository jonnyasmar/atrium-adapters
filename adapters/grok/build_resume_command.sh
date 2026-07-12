#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Grok session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["grok", ...flags, "-r", "session-id"]}
#
# Same `--rules` injection as launch — covers sessions started before the
# rules wiring existed, and any resume path that re-evaluates argv. See
# atrium-session-rules.sh.

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq &>/dev/null; then
  # Minimal fallback without jq — no rules, escape session id best-effort.
  ESCAPED_SESSION_ID="$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  echo "{\"command\": [\"grok\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq empty 2>/dev/null; then
  FLAGS='{}'
fi

RULES=""
if [ -x "${SCRIPT_DIR}/atrium-session-rules.sh" ] || [ -f "${SCRIPT_DIR}/atrium-session-rules.sh" ]; then
  RULES="$(bash "${SCRIPT_DIR}/atrium-session-rules.sh" 2>/dev/null || true)"
fi

jq -n \
  --argjson flags "$FLAGS" \
  --arg rules "$RULES" \
  --arg session "$SESSION_ID" \
  '{
    command:
      ["grok"]
      + (if $flags.alwaysApprove == true then ["--always-approve"] else [] end)
      + (if (($flags.model // "") | length) > 0 then ["--model", $flags.model] else [] end)
      + (if (($flags.effort // "") | length) > 0 then ["--reasoning-effort", $flags.effort] else [] end)
      + (
          if (($flags.extraArgs // "") | length) > 0
          then ($flags.extraArgs | split(" ") | map(select(length > 0)))
          else []
          end
        )
      + (if ($rules | length) > 0 then ["--rules", $rules] else [] end)
      + ["-r", $session]
  }'
exit 0

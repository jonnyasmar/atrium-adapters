#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Grok session.
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["env", "GROK_DISABLE_AUTOUPDATER=1", "<wrapper>", ...flags, "-r", "session-id"]}
#
# Same wrapper + Apple-jq-safe single-line filter as build_launch_command.sh.

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/grok-with-atrium-rules.sh"

if [ ! -f "$WRAPPER" ]; then
  if command -v jq &>/dev/null; then
    jq -nc --arg s "$SESSION_ID" '{command: ["env", "GROK_DISABLE_AUTOUPDATER=1", "grok", "-r", $s]}'
  else
    ESCAPED_SESSION_ID="$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    echo "{\"command\": [\"GROK_DISABLE_AUTOUPDATER=1\", \"grok\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
  fi
  exit 0
fi

if ! command -v jq &>/dev/null; then
  ESCAPED_WRAPPER="$(printf '%s' "$WRAPPER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  ESCAPED_SESSION_ID="$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  echo "{\"command\": [\"GROK_DISABLE_AUTOUPDATER=1\", \"${ESCAPED_WRAPPER}\", \"-r\", \"${ESCAPED_SESSION_ID}\"]}"
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq empty 2>/dev/null; then
  FLAGS='{}'
fi

jq -nc \
  --arg wrapper "$WRAPPER" \
  --argjson flags "$FLAGS" \
  --arg session "$SESSION_ID" \
  '{command: (["env", "GROK_DISABLE_AUTOUPDATER=1", $wrapper] + (if $flags.alwaysApprove == true then ["--always-approve"] else [] end) + (if (($flags.model // "") | length) > 0 then ["--model", $flags.model] else [] end) + (if (($flags.effort // "") | length) > 0 then ["--reasoning-effort", $flags.effort] else [] end) + (if (($flags.extraArgs // "") | length) > 0 then ($flags.extraArgs | split(" ") | map(select(length > 0))) else [] end) + ["-r", $session])}'
exit 0

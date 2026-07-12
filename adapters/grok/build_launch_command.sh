#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Grok.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["grok", ...flags]}
#
# Always appends `--rules <atrium session rules>` so atrium-context + the
# pane-rename instruction reach Grok's system prompt. Grok hooks cannot
# inject SessionStart/UserPromptSubmit context (passive stdout) — see
# atrium-session-rules.sh.

FLAGS="${1:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v jq &>/dev/null; then
  echo '{"command": ["grok"]}'
  exit 0
fi

# Guard against non-JSON flags so --argjson never aborts the launch path.
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
  }'
exit 0

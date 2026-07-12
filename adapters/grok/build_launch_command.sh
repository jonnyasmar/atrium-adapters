#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Grok.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["<wrapper>", ...flags]}
#
# argv[0] is grok-with-atrium-rules.sh (not bare `grok`) so atrium-context
# + the pane-rename instruction are injected via `grok --rules` inside the
# wrapper. We must NOT put multi-line rules text in this argv — atrium
# types it into the shell with an unquoted `cmd.join(" ")`, and newlines
# submit a broken partial command.

FLAGS="${1:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/grok-with-atrium-rules.sh"

if ! command -v jq &>/dev/null; then
  jq_fallback=1
else
  jq_fallback=0
fi

if [ "$jq_fallback" -eq 1 ] || ! printf '%s' "$FLAGS" | jq empty 2>/dev/null; then
  # Minimal path: wrapper only (or bare grok if wrapper missing).
  if [ -f "$WRAPPER" ]; then
    jq -n --arg w "$WRAPPER" '{command: [$w]}' 2>/dev/null \
      || printf '{"command":["%s"]}\n' "$WRAPPER"
  else
    echo '{"command": ["grok"]}'
  fi
  exit 0
fi

jq -n \
  --arg wrapper "$WRAPPER" \
  --argjson flags "$FLAGS" \
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
  }'
exit 0

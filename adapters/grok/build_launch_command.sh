#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Grok.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["GROK_DISABLE_AUTOUPDATER=1", "<wrapper>", ...flags]}
#
# argv[0] is grok-with-atrium-rules.sh (not bare `grok`) so atrium-context
# + the pane-rename instruction are injected via `grok --rules` inside the
# wrapper. Multi-line rules must NOT appear in this argv — atrium types it
# into the shell with an unquoted `cmd.join(" ")`.
#
# jq filter is a single expression with explicit parens: atrium's script
# PATH prefers /usr/bin/jq (Apple 1.7.1), which rejects multi-line
# `command: [$x] + …` without grouping (homebrew jq 1.8 is more lenient).

FLAGS="${1:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/grok-with-atrium-rules.sh"

if [ ! -f "$WRAPPER" ]; then
  echo '{"command": ["GROK_DISABLE_AUTOUPDATER=1", "grok"]}'
  exit 0
fi

if ! command -v jq &>/dev/null; then
  printf '{"command":["GROK_DISABLE_AUTOUPDATER=1",%s]}\n' "$(printf '%s' "$WRAPPER" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq empty 2>/dev/null; then
  FLAGS='{}'
fi

jq -nc \
  --arg wrapper "$WRAPPER" \
  --argjson flags "$FLAGS" \
  '{command: (["GROK_DISABLE_AUTOUPDATER=1", $wrapper] + (if $flags.alwaysApprove == true then ["--always-approve"] else [] end) + (if (($flags.model // "") | length) > 0 then ["--model", $flags.model] else [] end) + (if (($flags.effort // "") | length) > 0 then ["--reasoning-effort", $flags.effort] else [] end) + (if (($flags.extraArgs // "") | length) > 0 then ($flags.extraArgs | split(" ") | map(select(length > 0))) else [] end))}'
exit 0

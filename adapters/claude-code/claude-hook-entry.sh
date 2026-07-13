#!/usr/bin/env bash
# claude-hook-entry.sh — invoked by Claude Code for each configured hook event.
#
# Why a script file instead of an inline shell command in settings.json:
# Cursor Agent also discovers and executes ~/.claude/settings.json hooks.
# When those inline commands emit as --adapter claude-code with a Cursor
# payload, atrium's first-wins session binding mislabels the Cursor pane
# as Claude Code. Centralizing emit here lets us refuse to speak when the
# host is not Claude Code.
#
# Args:
#   $1  atrium event name (kebab-case: session-start, pre-tool-use, ...)
#
# Stdin:
#   JSON payload from the host (may be empty for some events).
#
# Side-effect:
#   Emits an atrium hook event as claude-code — unless this invocation
#   is clearly from Cursor Agent (env and/or payload shape).

set -u

EVENT="${1:?event name required}"
ATRIUM_CLI="${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZER="${ADAPTER_DIR}/normalize-hook-payload.sh"

# Cursor Agent sets this when invoked as `cursor-agent` / `agent`. Real
# Claude Code never does. Bail before we claim the pane as claude-code.
if [ -n "${CURSOR_INVOKED_AS:-}" ]; then
  exit 0
fi

input="$(cat)"

# Payload-shape guard: Cursor-shaped hooks carry generation_id and/or
# is_background_agent; real Claude Code session/tool payloads do not.
# (Claude uses transcript_path + session_id; Cursor uses conversation_id
# + generation_id + model: composer-*.) Empty/non-object stdin is fine —
# pass through so bare lifecycle pings still work under Claude.
if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | jq -e '
    type == "object"
    and (has("generation_id") or has("is_background_agent"))
  ' >/dev/null 2>&1; then
    exit 0
  fi
fi

# post-tool-use / stop: enrich via the normalizer first (write envelope /
# last_assistant_message). Other events stream straight to emit.
if { [ "$EVENT" = "post-tool-use" ] || [ "$EVENT" = "stop" ]; } \
  && [ -x "$NORMALIZER" ]; then
  printf '%s' "$input" \
    | "$NORMALIZER" "$EVENT" 2>/dev/null \
    | "$ATRIUM_CLI" hook emit "$EVENT" \
        --adapter claude-code \
        --pane-id "${ATRIUM_PANE_ID:-}" \
        --json 2>/dev/null
else
  printf '%s' "$input" \
    | "$ATRIUM_CLI" hook emit "$EVENT" \
        --adapter claude-code \
        --pane-id "${ATRIUM_PANE_ID:-}" \
        --json 2>/dev/null
fi

# Never break the agent session on emit failure.
exit 0

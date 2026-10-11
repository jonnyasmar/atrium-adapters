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

# Chat sidecar owns atrium hooks via SDK callbacks (ATRIUM_CHAT_SDK_HOOKS=1
# from build_chat_env) — skip shell dual-fire for every event.
if [ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]; then
  exit 0
fi

EVENT="${1:?event name required}"

# Cursor Agent sets this when invoked as `cursor-agent` / `agent`. Real
# Claude Code never does. Bail before we claim the pane as claude-code.
if [ -n "${CURSOR_INVOKED_AS:-}" ]; then
  exit 0
fi

# Claude Code refuses its native bypass mode under uid 0. A root terminal
# launched from an atrium YOLO profile carries this process-local marker, so
# approve the permission request on the user's behalf without changing their
# persisted Claude settings. AskUserQuestion is not a permission request and
# still reaches the user, matching native bypass behavior.
reply_root_bypass() {
  if [ "$EVENT" = "permission-request" ] \
    && [ "${ATRIUM_CLAUDE_ROOT_BYPASS_PERMISSIONS:-}" = "1" ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
  fi
}

# settings.json is global, so this also runs for Claude Code sessions with no
# atrium pane (started outside atrium, or a quarantined sign-in TUI). An emit
# there has nothing to attribute the event to, so skip it, and the subshells
# and CLI spawn it costs, before doing any work.
if [ -z "${ATRIUM_PANE_ID:-}" ]; then
  reply_root_bypass
  exit 0
fi

ATRIUM_CLI="${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZER="${ADAPTER_DIR}/normalize-hook-payload.sh"

input="$(cat)"

# Payload-shape guard: real Claude Code payloads always carry snake_case
# session_id (+ transcript_path). Cursor-shaped hooks carry generation_id
# and/or is_background_agent; Grok scans ~/.claude/settings.json for hooks
# and dual-fires them with its own camelCase shape (hookEventName/sessionId,
# no session_id). Refuse to claim the pane as claude-code for any of these —
# a foreign emit wedges the pane's fleet status under the wrong adapter.
# Empty/non-object stdin is fine — pass through so bare lifecycle pings
# still work under Claude.
if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | jq -e '
    type == "object"
    and (
      has("generation_id") or has("is_background_agent")
      or has("hookEventName")
      or (has("session_id") | not)
    )
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

reply_root_bypass

# Never break the agent session on emit failure.
exit 0

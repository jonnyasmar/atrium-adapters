#!/usr/bin/env bash
# inject-context.sh — codex context injection via the hook server's
# context_injection pipeline (Epic 77).
#
# Usage: inject-context.sh <event>
#   event = session-start | user-prompt-submit | pre-tool-use | post-tool-use
#
# Atrium's context providers (Story 77.5: RunCommandStatusProvider) run in the
# hook server's context_injection pipeline (Story 77.4) and the assembled
# envelope rides the `atriumContext` field on the hook server's
# /api/adapter/<adapter>/<event> JSON response (Story 77.5). This script is the
# codex delivery: it POSTs the native hook payload to the hook server's HTTP
# route, reads `atriumContext`, and re-emits it in codex's native envelope for
# that event. codex (unlike claude-code, whose SessionStart consumes raw
# stdout) consumes the hookSpecificOutput envelope at every injectable event
# (live-probed):
#   {"hookSpecificOutput": {"hookEventName": "SessionStart"|"UserPromptSubmit"
#                           |"PreToolUse"|"PostToolUse",
#                           "additionalContext": <envelope>}}
# Epic 78 Story 78.3 adds user-prompt-submit (the context-injection pipeline
# atriumContext, additive to the existing sigil/nudge UserPromptSubmit entries)
# and post-tool-use (whose payload carries the tool RESULT for post-action
# providers).
#
# When there's nothing to inject (or anything fails) it emits the per-event
# no-op (empty for raw SessionStart, `{}` for JSON-envelope events) and exits 0
# — the hook NEVER blocks the session or tool call (fail-open, NFR5 / Rule 7).
# Budget: ONE HTTP round-trip to localhost.
set -uo pipefail

EVENT="${1:-}"

# Per-event no-op. SessionStart consumes raw stdout, so its no-op is empty;
# Codex's strict parser requires `{}` for JSON-envelope events.
noop() {
  case "$EVENT" in
    user-prompt-submit | pre-tool-use | post-tool-use) printf '%s\n' '{}' ;;
    *) : ;;
  esac
  exit 0
}

# Chat sidecar owns injection. Keep the native hook parser satisfied without
# contacting the hook server or double-delivering daemon-owned context.
[ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || noop

case "$EVENT" in
  session-start | user-prompt-submit | pre-tool-use | post-tool-use) ;;
  *) noop ;;
esac

command -v jq >/dev/null 2>&1 || noop
command -v curl >/dev/null 2>&1 || noop
[ -n "${ATRIUM:-}" ] || noop

# Drain the native hook stdin payload (PreToolUse carries tool_name). A
# subsequent jq that BUILDS json must use `jq -n` (stdin already consumed — the
# drained-stdin gotcha). Empty/garbage degrades to `{}` so we still POST.
payload="$(cat 2>/dev/null || true)"
if [ -z "$payload" ] || ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  payload='{}'
fi

# Discover the hook server port (written by the running app, per data-dir).
data_dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}"
port_file="${data_dir}/hook-port"
[ -f "$port_file" ] || noop
port="$(cat "$port_file" 2>/dev/null || true)"
[ -n "$port" ] || noop

# POST to the hook server's route for this event. The pane id rides the
# X-Atrium-Pane-Id header (the route reads it for pane→workspace resolution).
# Short timeouts keep the hook well under budget; any failure → no-op.
response="$(curl -fsS \
  --max-time 2 \
  --connect-timeout 1 \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}" \
  --data-binary "$payload" \
  "http://127.0.0.1:${port}/api/adapter/codex/${EVENT}" 2>/dev/null || true)"

[ -n "$response" ] || noop

# Extract the assembled envelope. Absent / null ⇒ nothing to inject ⇒ no-op.
context="$(printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true)"
[ -n "$context" ] || noop

# Render codex's native hookSpecificOutput envelope. `jq -n` because stdin is
# drained. codex consumes this shape at every injectable event.
case "$EVENT" in
  session-start) hook_event_name="SessionStart" ;;
  user-prompt-submit) hook_event_name="UserPromptSubmit" ;;
  pre-tool-use) hook_event_name="PreToolUse" ;;
  post-tool-use) hook_event_name="PostToolUse" ;;
esac
jq -n --arg name "$hook_event_name" --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
exit 0

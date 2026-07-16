#!/usr/bin/env bash
# inject-context.sh — claude-code context injection via the hook server's
# context_injection pipeline (Epic 77).
#
# Usage: inject-context.sh <event>
#   event = session-start | user-prompt-submit | pre-tool-use | post-tool-use
#
# Atrium's context providers (Story 77.5: RunCommandStatusProvider) run in the
# hook server's context_injection pipeline (Story 77.4) and the assembled
# envelope rides the `atriumContext` field on the hook server's
# /api/adapter/<adapter>/<event> JSON response (Story 77.5). This script is the
# claude-code delivery: it POSTs the native hook payload to the hook server's
# HTTP route, reads `atriumContext`, and re-emits it in Claude Code's native
# envelope for that event:
#   - session-start    → raw text on stdout (identity envelope: Claude treats
#     SessionStart hook stdout as additionalContext directly).
#   - user-prompt-submit → {"hookSpecificOutput": {"hookEventName":
#     "UserPromptSubmit", "additionalContext": <envelope>}} (Epic 78 Story 78.3:
#     the context-injection pipeline atriumContext, additive to the existing
#     sigil/nudge UserPromptSubmit entries).
#   - pre-tool-use     → {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#     "additionalContext": <envelope>}}.
#   - post-tool-use    → {"hookSpecificOutput": {"hookEventName": "PostToolUse",
#     "additionalContext": <envelope>}} (Epic 78 Story 78.3: the PostToolUse
#     payload carries the tool RESULT, so a post-action provider can read it).
#
# When there's nothing to inject (or anything fails) it emits the per-event
# no-op (empty body for session-start, `{}` for the JSON-envelope events) and
# exits 0 — the hook NEVER blocks the session or the tool call (fail-open,
# NFR5 / Rule 7). Budget: ONE HTTP round-trip to localhost.
set -uo pipefail

# Chat sidecar owns injection via SDK hooks — skip shell dual-fire.
# Still emit the per-event no-op so strict JSON hook parsers stay happy.
if [ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]; then
  case "${1:-}" in
    user-prompt-submit | pre-tool-use | post-tool-use) printf '%s\n' '{}' ;;
  esac
  exit 0
fi

EVENT="${1:-}"

# Per-event no-op: SessionStart consumes raw stdout, so its no-op is an EMPTY
# body; the JSON-envelope events expect a JSON envelope, so their no-op is `{}`.
noop() {
  case "$EVENT" in
    user-prompt-submit | pre-tool-use | post-tool-use) printf '%s\n' '{}' ;;
    *) : ;; # session-start (and anything else): empty body
  esac
  exit 0
}

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
  "http://127.0.0.1:${port}/api/adapter/claude-code/${EVENT}" 2>/dev/null || true)"

[ -n "$response" ] || noop

# Extract the assembled envelope. Absent / null ⇒ nothing to inject ⇒ no-op.
context="$(printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true)"
[ -n "$context" ] || noop

# Render the per-event native envelope. `jq -n` because stdin is drained. The
# JSON-envelope events share the hookSpecificOutput shape, differing only in
# hookEventName; SessionStart is the identity (raw-text) exception.
case "$EVENT" in
  session-start)
    # Identity envelope: Claude treats SessionStart hook stdout as context.
    printf '%s\n' "$context"
    ;;
  user-prompt-submit) hook_event_name="UserPromptSubmit" ;;
  pre-tool-use) hook_event_name="PreToolUse" ;;
  post-tool-use) hook_event_name="PostToolUse" ;;
esac
case "$EVENT" in
  user-prompt-submit | pre-tool-use | post-tool-use)
    jq -n --arg name "$hook_event_name" --arg ctx "$context" \
      '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
    ;;
esac
exit 0

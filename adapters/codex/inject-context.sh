#!/usr/bin/env bash
# inject-context.sh — codex context injection via the hook server's
# context_injection pipeline (Epic 77).
#
# Usage: inject-context.sh <event>
#   event = session-start | pre-tool-use
#
# Atrium's context providers (Story 77.5: RunCommandStatusProvider) run in the
# hook server's context_injection pipeline (Story 77.4) and the assembled
# envelope rides the `atriumContext` field on the hook server's
# /api/adapter/<adapter>/<event> JSON response (Story 77.5). This script is the
# codex delivery: it POSTs the native hook payload to the hook server's HTTP
# route, reads `atriumContext`, and re-emits it in codex's native envelope for
# that event. codex (unlike claude-code, whose SessionStart consumes raw
# stdout) consumes the hookSpecificOutput envelope at BOTH SessionStart and
# PreToolUse (live-probed):
#   {"hookSpecificOutput": {"hookEventName": "SessionStart"|"PreToolUse",
#                           "additionalContext": <envelope>}}
#
# When there's nothing to inject (or anything fails) it emits the `{}` no-op and
# exits 0 — the hook NEVER blocks the session or the tool call (fail-open, NFR5
# / Rule 7). codex 0.120+ strictly parses hook stdout as a JSON envelope, so the
# no-op is `{}` (not an empty body). Budget: ONE HTTP round-trip to localhost.
set -uo pipefail

EVENT="${1:-}"

# Per-event no-op. codex's strict JSON parser wants a well-formed envelope even
# when there's nothing to inject, so the no-op is `{}` for every event.
noop() {
  printf '%s\n' '{}'
  exit 0
}

case "$EVENT" in
  session-start | pre-tool-use) ;;
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
# drained. codex consumes this shape at both SessionStart and PreToolUse.
case "$EVENT" in
  pre-tool-use) hook_event_name="PreToolUse" ;;
  session-start) hook_event_name="SessionStart" ;;
esac
jq -n --arg name "$hook_event_name" --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
exit 0

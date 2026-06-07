#!/usr/bin/env bash
# inject-context.sh — cursor-agent context injection via the hook server's
# context_injection pipeline (Epic 77, Story 77.5).
#
# Usage: inject-context.sh <event>
#   event = session-start
#
# Atrium's context providers (Story 77.5: RunCommandStatusProvider) run in the
# hook server's context_injection pipeline (Story 77.4) and the assembled
# envelope rides the `atriumContext` field on the hook server's
# /api/adapter/<adapter>/<event> JSON response. This script is the cursor-agent
# delivery: it POSTs the native hook payload to the hook server's HTTP route,
# reads `atriumContext`, and re-emits it in Cursor's native sessionStart
# envelope: `{"additional_context": "<ctx>"}` (per cursor.com/docs/hooks —
# Cursor parses sessionStart hook stdout as JSON and injects
# `additional_context` as session context).
#
# cursor-agent is injection-CAPABLE at sessionStart ONLY. PreToolUse is NOT
# wired: Cursor's preToolUse `agent_message` only surfaces on a deny decision,
# not at the injection point, so it's incapable (adapter.json keeps
# preToolUse: none — no dead wiring, per the grok-revert lesson).
#
# When there's nothing to inject (or anything fails) it emits `{}` and exits 0 —
# Cursor expects JSON on stdout, and an empty object is the no-op. The hook
# NEVER blocks the session (fail-open, NFR5 / Rule 7). Budget: ONE HTTP
# round-trip to localhost.
set -uo pipefail

EVENT="${1:-}"

# No-op: Cursor parses sessionStart hook stdout as JSON, so the no-op is an
# empty object (nothing to inject) — not an empty body.
noop() {
  printf '%s\n' '{}'
  exit 0
}

case "$EVENT" in
  session-start) ;;
  *) noop ;;
esac

command -v jq >/dev/null 2>&1 || noop
command -v curl >/dev/null 2>&1 || noop
[ -n "${ATRIUM:-}" ] || noop

# Drain the native hook stdin payload. A subsequent jq that BUILDS json must
# use `jq -n` (stdin already consumed — the drained-stdin gotcha). Empty/garbage
# degrades to `{}` so we still POST.
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
  "http://127.0.0.1:${port}/api/adapter/cursor-agent/${EVENT}" 2>/dev/null || true)"

[ -n "$response" ] || noop

# Extract the assembled envelope. Absent / null ⇒ nothing to inject ⇒ no-op.
context="$(printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true)"
[ -n "$context" ] || noop

# Render Cursor's native sessionStart envelope. `jq -n` because stdin is drained.
jq -n --arg ctx "$context" '{additional_context: $ctx}'
exit 0

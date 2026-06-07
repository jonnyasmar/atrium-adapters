#!/usr/bin/env bash
# inject-context.sh — gemini context injection via the hook server's
# context_injection pipeline (Epic 77).
#
# Usage: inject-context.sh <event> [data-dir]
#   event    = session-start
#   data-dir = optional atrium data dir (hooks.sh bakes the install-time channel
#              fallback here because gemini strips ATRIUM_* vars at hook-fire
#              time; runtime $ATRIUM_DATA_DIR still wins when present).
#
# Atrium's context providers (Story 77.5: RunCommandStatusProvider) run in the
# hook server's context_injection pipeline (Story 77.4) and the assembled
# envelope rides the `atriumContext` field on the hook server's
# /api/adapter/<adapter>/<event> JSON response (Story 77.5). This script is the
# gemini delivery: it POSTs the native hook payload to the hook server's HTTP
# route, reads `atriumContext`, and re-emits it in Gemini CLI's native
# SessionStart envelope:
#   - session-start → {"hookSpecificOutput": {"hookEventName": "SessionStart",
#     "additionalContext": <ctx>}} on stdout (Gemini parses SessionStart hook
#     stdout as JSON and injects additionalContext — matches adapter.json
#     hookEnvelopes.sessionStartManifest).
#
# gemini is injection-CAPABLE at SessionStart ONLY. It exposes NO
# additionalContext channel at BeforeTool/PreToolUse, so adapter.json declares
# hookEnvelopes.preToolUse = none and this script wires no PreToolUse delivery
# (the grok-revert lesson: no dead wiring).
#
# No `[ -n "${ATRIUM:-}" ]` fast-path guard: gemini strips ATRIUM_* vars at
# hook-fire time, so gating on $ATRIUM would make this always no-op. The
# hook-port discovery + HTTP fail-open already guarantee a clean no-op outside a
# running atrium (matches the SessionStart resolve-manifest precedent, which
# also omits the guard for the same reason).
#
# When there's nothing to inject (or anything fails) it emits the no-op envelope
# (`{}`) and exits 0 — the hook NEVER blocks session start (fail-open, NFR5 /
# Rule 7). Budget: ONE HTTP round-trip to localhost.
set -uo pipefail

EVENT="${1:-}"

# Gemini parses SessionStart hook stdout as JSON, so the no-op is the empty
# JSON object `{}` (an empty body would not parse). Any unknown event also
# degrades to the no-op.
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

# Drain the native hook stdin payload. A subsequent jq that BUILDS json must use
# `jq -n` (stdin already consumed — the drained-stdin gotcha). Empty/garbage
# degrades to `{}` so we still POST.
payload="$(cat 2>/dev/null || true)"
if [ -z "$payload" ] || ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  payload='{}'
fi

# Discover the hook server port (written by the running app, per data-dir).
# Runtime $ATRIUM_DATA_DIR wins; the install-time fallback baked into $2 by
# hooks.sh covers gemini stripping the env var; plain $HOME/.atrium is the
# last resort.
data_dir="${ATRIUM_DATA_DIR:-${2:-$HOME/.atrium}}"
port_file="${data_dir}/hook-port"
[ -f "$port_file" ] || noop
port="$(cat "$port_file" 2>/dev/null || true)"
[ -n "$port" ] || noop

# POST to the hook server's gemini route for this event. The pane id rides the
# X-Atrium-Pane-Id header (the route reads it for pane→workspace resolution).
# Short timeouts keep the hook well under budget; any failure → no-op.
response="$(curl -fsS \
  --max-time 2 \
  --connect-timeout 1 \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}" \
  --data-binary "$payload" \
  "http://127.0.0.1:${port}/api/adapter/gemini/${EVENT}" 2>/dev/null || true)"

[ -n "$response" ] || noop

# Extract the assembled envelope. Absent / null ⇒ nothing to inject ⇒ no-op.
context="$(printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true)"
[ -n "$context" ] || noop

# Render Gemini's native SessionStart envelope. `jq -n` because stdin is drained.
jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0

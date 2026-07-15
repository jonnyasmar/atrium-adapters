#!/usr/bin/env bash
# inject-context.sh — Grok event-hook context delivery.
# Usage: inject-context.sh <session-start|user-prompt-submit|pre-tool-use|post-tool-use>
set -uo pipefail

EVENT="${1:-}"

noop() {
  printf '%s\n' '{}'
  exit 0
}

case "$EVENT" in
  session-start | user-prompt-submit | pre-tool-use | post-tool-use) ;;
  *) noop ;;
esac

command -v jq >/dev/null 2>&1 || noop
command -v curl >/dev/null 2>&1 || noop
[ -n "${ATRIUM:-}" ] || noop

payload="$(cat 2>/dev/null || true)"
if [ -z "$payload" ] || ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  payload='{}'
fi

data_dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}"
port_file="${data_dir}/hook-port"
[ -f "$port_file" ] || noop
port="$(cat "$port_file" 2>/dev/null || true)"
[ -n "$port" ] || noop

response="$(curl -fsS \
  --max-time 2 \
  --connect-timeout 1 \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}" \
  --data-binary "$payload" \
  "http://127.0.0.1:${port}/api/adapter/grok/${EVENT}" 2>/dev/null || true)"

[ -n "$response" ] || noop
context="$(printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true)"
[ -n "$context" ] || noop

case "$EVENT" in
  session-start) hook_event_name="SessionStart" ;;
  user-prompt-submit) hook_event_name="UserPromptSubmit" ;;
  pre-tool-use) hook_event_name="PreToolUse" ;;
  post-tool-use) hook_event_name="PostToolUse" ;;
esac

jq -n --arg name "$hook_event_name" --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
exit 0

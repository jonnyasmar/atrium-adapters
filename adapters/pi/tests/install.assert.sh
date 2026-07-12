#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the pi adapter.
# Verifies that ~/.pi/agent/extensions/atrium.ts exists, carries the
# atrium marker, and exports a default factory function that subscribes
# to pi's documented events (session_start, session_shutdown, tool_call,
# tool_result, input, agent_end).

EXT_FILE="${HOME}/.pi/agent/extensions/atrium.ts"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$EXT_FILE" ]]; then
  echo "install.assert: $EXT_FILE does not exist" >&2
  exit 1
fi

if ! grep -q 'ATRIUM_HOOK_MARKER=atrium-runtime-hook' "$EXT_FILE"; then
  echo "install.assert: $EXT_FILE missing atrium marker" >&2
  exit 1
fi

if ! grep -q 'export default function' "$EXT_FILE"; then
  echo "install.assert: $EXT_FILE missing 'export default function' (pi extension shape)" >&2
  exit 1
fi

if ! grep -q 'getSessionId' "$EXT_FILE"; then
  echo "install.assert: $EXT_FILE does not use pi's canonical session id" >&2
  exit 1
fi

# All wired pi events must be present.
for event in '"session_start"' '"session_shutdown"' '"tool_call"' '"tool_result"' '"input"' '"agent_end"'; do
  if ! grep -q "pi.on($event" "$EXT_FILE"; then
    echo "install.assert: $EXT_FILE missing pi.on($event ...) handler" >&2
    exit 1
  fi
done

UUID="019f58a2-a92b-7725-b177-240aa09c0736"
LEGACY_ID="2026-07-12T23-21-22-987Z_${UUID}"
RESUME_ID="$($ADAPTER_DIR/build_resume_command.sh "$LEGACY_ID" '{}' | jq -r '.command[2]')"
if [[ "$RESUME_ID" != "$UUID" ]]; then
  echo "install.assert: legacy pi session id normalized to '$RESUME_ID', expected '$UUID'" >&2
  exit 1
fi

RESUME_ID="$($ADAPTER_DIR/build_resume_command.sh "$UUID" '{}' | jq -r '.command[2]')"
if [[ "$RESUME_ID" != "$UUID" ]]; then
  echo "install.assert: canonical pi session id changed to '$RESUME_ID'" >&2
  exit 1
fi

exit 0

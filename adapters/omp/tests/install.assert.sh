#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the omp adapter.
# Verifies that ~/.omp/agent/extensions/atrium.ts exists, carries the
# atrium marker, and exports a default factory function that subscribes
# to pi's documented events (session_start, session_shutdown, tool_call,
# tool_result, input, agent_end).

EXT_FILE="${HOME}/.omp/agent/extensions/atrium.ts"

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

if ! grep -q 'ATRIUM_INPUT_REQUEST_TOOLS_OMP' "$EXT_FILE"; then
  echo "install.assert: $EXT_FILE missing configurable input-request tools" >&2
  exit 1
fi

if ! grep -q 'emit("permission-request"' "$EXT_FILE"; then
  echo "install.assert: $EXT_FILE does not emit permission-request for input tools" >&2
  exit 1
fi

# All wired pi events must be present.
for event in '"session_start"' '"session_shutdown"' '"tool_call"' '"tool_result"' '"input"' '"agent_end"'; do
  if ! grep -q "pi.on($event" "$EXT_FILE"; then
    echo "install.assert: $EXT_FILE missing pi.on($event ...) handler" >&2
    exit 1
  fi
done

# omp 18.8.9 advertises promptCapabilities.image=true and hands a
# session/prompt image block to the model (probed 2026-10-11). Only this flag
# lets the new-chat launcher attach a pasted image before the session starts.
ADAPTER_JSON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/adapter.json"
if ! jq -e '.chatTransport.capabilities.imageInput == true' "$ADAPTER_JSON" >/dev/null; then
  echo "install.assert: chatTransport.capabilities.imageInput must be true" >&2
  exit 1
fi

exit 0

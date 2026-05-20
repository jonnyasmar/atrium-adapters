#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the opencode adapter.
# Verifies that ~/.config/opencode/plugins/atrium.js exists, carries the
# atrium marker, and exports the AtriumPlugin factory + a default export.

PLUGIN_FILE="${HOME}/.config/opencode/plugins/atrium.js"

if [[ ! -f "$PLUGIN_FILE" ]]; then
  echo "install.assert: $PLUGIN_FILE does not exist" >&2
  exit 1
fi

if ! grep -q 'ATRIUM_HOOK_MARKER=atrium-runtime-hook' "$PLUGIN_FILE"; then
  echo "install.assert: $PLUGIN_FILE missing atrium marker" >&2
  exit 1
fi

# The plugin must export AtriumPlugin (named) and a default. Both shapes
# are provided so opencode loads it under any convention.
if ! grep -q 'export const AtriumPlugin' "$PLUGIN_FILE"; then
  echo "install.assert: $PLUGIN_FILE missing 'export const AtriumPlugin'" >&2
  exit 1
fi

if ! grep -q 'export default' "$PLUGIN_FILE"; then
  echo "install.assert: $PLUGIN_FILE missing default export" >&2
  exit 1
fi

# All the documented event keys we wire from @opencode-ai/plugin's Hooks
# interface must be present in the plugin source.
for hook in '"event"' '"chat.message"' '"tool.execute.before"' '"tool.execute.after"' '"permission.ask"'; do
  if ! grep -q "$hook" "$PLUGIN_FILE"; then
    echo "install.assert: $PLUGIN_FILE missing handler key $hook" >&2
    exit 1
  fi
done

exit 0

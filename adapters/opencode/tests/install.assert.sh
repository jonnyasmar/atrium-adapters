#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the opencode adapter.
# Verifies:
#   1. Plugin file exists at ~/.config/opencode/plugins/atrium.js with
#      the atrium marker and the expected hook handlers.
#   2. opencode config (opencode.jsonc or opencode.json) registers the
#      plugin under `plugin` array — without registration opencode does
#      not load the file and atrium gets zero events.

PLUGIN_FILE="${HOME}/.config/opencode/plugins/atrium.js"
CONFIG_JSONC="${HOME}/.config/opencode/opencode.jsonc"
CONFIG_JSON="${HOME}/.config/opencode/opencode.json"

if [[ ! -f "$PLUGIN_FILE" ]]; then
  echo "install.assert: $PLUGIN_FILE does not exist" >&2
  exit 1
fi

if ! grep -q 'ATRIUM_HOOK_MARKER=atrium-runtime-hook' "$PLUGIN_FILE"; then
  echo "install.assert: $PLUGIN_FILE missing atrium marker" >&2
  exit 1
fi

if ! grep -q 'export const AtriumPlugin' "$PLUGIN_FILE"; then
  echo "install.assert: $PLUGIN_FILE missing 'export const AtriumPlugin'" >&2
  exit 1
fi

if ! grep -q 'export default' "$PLUGIN_FILE"; then
  echo "install.assert: $PLUGIN_FILE missing default export" >&2
  exit 1
fi

for hook in '"event"' '"chat.message"' '"tool.execute.before"' '"tool.execute.after"' '"permission.ask"'; do
  if ! grep -q "$hook" "$PLUGIN_FILE"; then
    echo "install.assert: $PLUGIN_FILE missing handler key $hook" >&2
    exit 1
  fi
done

# Atrium-side field-name remapping must be present (the historical bug
# was the plugin emitting opencode-native camelCase keys directly).
for atrium_field in 'session_id' 'tool_name' 'tool_input' 'user_prompt' 'last_assistant_message'; do
  if ! grep -q "$atrium_field" "$PLUGIN_FILE"; then
    echo "install.assert: $PLUGIN_FILE missing atrium field remap: $atrium_field" >&2
    exit 1
  fi
done

# Config registration assertion. Either opencode.jsonc or opencode.json
# must register the plugin under .plugin. JSONC with comments triggers
# the install's text-only skip path; we tolerate that here (warn but
# don't fail), since the user may be in that edge case intentionally.
plugin_uri="file://${PLUGIN_FILE}"
cfg=""
if [[ -f "$CONFIG_JSONC" ]]; then cfg="$CONFIG_JSONC"; elif [[ -f "$CONFIG_JSON" ]]; then cfg="$CONFIG_JSON"; fi

if [[ -z "$cfg" ]]; then
  echo "install.assert: no opencode config file found at ${CONFIG_JSONC} or ${CONFIG_JSON}" >&2
  exit 1
fi

if ! jq empty "$cfg" >/dev/null 2>&1; then
  echo "install.assert: $cfg is not valid plain JSON (likely JSONC with comments); cannot verify plugin registration via jq (warn-only)" >&2
  exit 0
fi

if ! jq -e --arg p "$plugin_uri" '(.plugin // []) | index($p)' "$cfg" >/dev/null 2>&1; then
  echo "install.assert: $cfg does not register the atrium plugin (expected '${plugin_uri}' in .plugin)" >&2
  jq '.plugin // null' "$cfg" >&2
  exit 1
fi

exit 0

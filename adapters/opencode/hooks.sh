#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage OpenCode hook installation for atrium.
# OpenCode has no JSON-based hook config — its plugin system is JS/TS only.
# We install a small plugin file (plugin/atrium.js) into
# ~/.config/opencode/plugins/atrium.js that subscribes to opencode's
# documented hook events and shells out to `atrium hook emit`.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
PLUGINS_DIR="${HOME}/.config/opencode/plugins"
PLUGIN_FILE="${PLUGINS_DIR}/atrium.js"

# Marker string that must appear in any atrium-owned plugin file. The plugin
# template embeds this string in a comment so status/uninstall can recognize
# our file (vs. a user-authored plugin that happens to share the name).
ATRIUM_PLUGIN_MARKER='ATRIUM_HOOK_MARKER=atrium-runtime-hook'

# Adapter dir, used to locate the bundled plugin template.
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SOURCE="${ADAPTER_DIR}/plugin/atrium.js"

is_atrium_plugin() {
  [ -f "$1" ] && grep -q "$ATRIUM_PLUGIN_MARKER" "$1"
}

do_install() {
  if [ ! -f "$PLUGIN_SOURCE" ]; then
    echo "{\"error\": \"plugin template not found at ${PLUGIN_SOURCE}\"}" >&2
    exit 1
  fi

  mkdir -p "$PLUGINS_DIR"

  # If an atrium plugin is already in place, overwrite it (refresh). If a
  # foreign atrium.js exists (no marker), bail rather than clobber the
  # user's file.
  if [ -f "$PLUGIN_FILE" ] && ! is_atrium_plugin "$PLUGIN_FILE"; then
    echo "{\"error\": \"~/.config/opencode/plugins/atrium.js exists and was not created by atrium; refusing to overwrite\"}" >&2
    exit 1
  fi

  cp "$PLUGIN_SOURCE" "$PLUGIN_FILE"

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ -f "$PLUGIN_FILE" ] && is_atrium_plugin "$PLUGIN_FILE"; then
    rm -f "$PLUGIN_FILE"
  fi
  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local installed="false"
  if is_atrium_plugin "$PLUGIN_FILE"; then
    installed="true"
  fi
  echo "{\"subcommand\": \"status\", \"installed\": ${installed}, \"activityHooks\": ${installed}}"
}

case "$SUBCOMMAND" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)
    echo "{\"error\": \"Unknown subcommand: ${SUBCOMMAND}\"}" >&2
    exit 2
    ;;
esac

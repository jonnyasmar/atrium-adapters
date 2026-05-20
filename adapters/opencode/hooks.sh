#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage OpenCode hook installation for atrium.
#
# OpenCode has no JSON-based hook config — its plugin system is JS/TS only.
# Install:
#   1. Drop the bundled plugin file at ~/.config/opencode/plugins/atrium.js
#   2. Register its absolute path in ~/.config/opencode/opencode.jsonc
#      under the `plugin` array — empirically, opencode does NOT auto-
#      discover from plugins/ in practice; explicit registration is what
#      actually causes the plugin to load. Without it the file sits on
#      disk forever and atrium gets zero hook events.
#
# The opencode.jsonc edit uses jq, which strips comments. We only touch
# the file if it's plain JSON (no // or /* */ comments); JSONC with
# comments triggers a warning and skips registration (user must add
# manually).
#
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
PLUGINS_DIR="${HOME}/.config/opencode/plugins"
PLUGIN_FILE="${PLUGINS_DIR}/atrium.js"
OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
OPENCODE_CONFIG_JSON="${HOME}/.config/opencode/opencode.json"

ATRIUM_PLUGIN_MARKER='ATRIUM_HOOK_MARKER=atrium-runtime-hook'

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SOURCE="${ADAPTER_DIR}/plugin/atrium.js"

is_atrium_plugin() {
  [ -f "$1" ] && grep -q "$ATRIUM_PLUGIN_MARKER" "$1"
}

# Locate the active opencode config file (prefer .jsonc if present,
# else .json). Echoes the path or empty if neither exists.
locate_config() {
  if [ -f "$OPENCODE_CONFIG" ]; then
    echo "$OPENCODE_CONFIG"
  elif [ -f "$OPENCODE_CONFIG_JSON" ]; then
    echo "$OPENCODE_CONFIG_JSON"
  else
    echo ""
  fi
}

# Returns 0 if the file is unsafe for jq (JSONC with comments / trailing
# commas / other non-JSON), 1 if it parses as plain JSON. The real test
# is jq itself — regex-based comment detection misfires on URIs like
# `file:///path` (triple-slash trips a naive `//` check) and on `$schema`
# URLs (`https://...`). If jq can't parse it, we treat it as JSONC and
# leave it untouched, asking the user to register manually.
has_jsonc_comments() {
  [ -f "$1" ] || return 1
  ! jq empty "$1" >/dev/null 2>&1
}

ensure_config_file() {
  mkdir -p "$(dirname "$OPENCODE_CONFIG")"
  if [ ! -f "$OPENCODE_CONFIG" ] && [ ! -f "$OPENCODE_CONFIG_JSON" ]; then
    printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$OPENCODE_CONFIG_JSON"
  fi
}

register_plugin_in_config() {
  ensure_config_file
  local cfg
  cfg="$(locate_config)"
  if [ -z "$cfg" ]; then
    echo "register: no opencode config file found" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "register: jq required" >&2
    return 1
  fi

  # If the file is empty or unparseable (zero bytes from a prior aborted
  # install, scratch file, etc.) seed it with `{}` so jq has something
  # to merge into. Pre-existing JSON content stays untouched.
  if [ ! -s "$cfg" ] || ! jq empty "$cfg" >/dev/null 2>&1; then
    if has_jsonc_comments "$cfg" && [ -s "$cfg" ]; then
      # Non-empty but unparseable — likely real JSONC with comments. Bail
      # rather than clobber the user's config.
      echo "register: $cfg contains JSONC comments; skipping registration. Add this manually to your config:" >&2
      echo "  \"plugin\": [\"file://${PLUGIN_FILE}\"]" >&2
      return 0
    fi
    # Empty file → safe to seed.
    printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$cfg"
  fi

  # Append our plugin file:// URI to the `plugin` array if not present.
  # opencode resolves "file://<absolute>" reliably across platforms.
  local plugin_uri="file://${PLUGIN_FILE}"
  local tmp="${cfg}.atrium-tmp"
  jq --arg p "$plugin_uri" '
    .plugin = ((.plugin // []) | map(select(. != $p)) + [$p])
  ' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
}

unregister_plugin_from_config() {
  local cfg
  cfg="$(locate_config)"
  [ -z "$cfg" ] && return 0

  if has_jsonc_comments "$cfg"; then
    echo "unregister: $cfg contains JSONC comments; skipping. Remove this entry manually if present:" >&2
    echo "  \"file://${PLUGIN_FILE}\"" >&2
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    return 0
  fi

  local plugin_uri="file://${PLUGIN_FILE}"
  local tmp="${cfg}.atrium-tmp"
  jq --arg p "$plugin_uri" '
    .plugin = ((.plugin // []) | map(select(. != $p))) |
    if (.plugin // []) | length == 0 then del(.plugin) else . end
  ' "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
}

do_install() {
  if [ ! -f "$PLUGIN_SOURCE" ]; then
    echo "{\"error\": \"plugin template not found at ${PLUGIN_SOURCE}\"}" >&2
    exit 1
  fi

  mkdir -p "$PLUGINS_DIR"

  if [ -f "$PLUGIN_FILE" ] && ! is_atrium_plugin "$PLUGIN_FILE"; then
    echo "{\"error\": \"~/.config/opencode/plugins/atrium.js exists and was not created by atrium; refusing to overwrite\"}" >&2
    exit 1
  fi

  cp "$PLUGIN_SOURCE" "$PLUGIN_FILE"
  register_plugin_in_config

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  unregister_plugin_from_config
  if [ -f "$PLUGIN_FILE" ] && is_atrium_plugin "$PLUGIN_FILE"; then
    rm -f "$PLUGIN_FILE"
  fi
  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local plugin_installed="false"
  local registered="false"

  if is_atrium_plugin "$PLUGIN_FILE"; then
    plugin_installed="true"
  fi

  local cfg
  cfg="$(locate_config)"
  if [ -n "$cfg" ] && ! has_jsonc_comments "$cfg" && command -v jq &>/dev/null; then
    local plugin_uri="file://${PLUGIN_FILE}"
    if jq -e --arg p "$plugin_uri" '(.plugin // []) | index($p)' "$cfg" >/dev/null 2>&1; then
      registered="true"
    fi
  fi

  # We consider the adapter installed only if BOTH the plugin file is
  # present AND opencode is registered to load it. File-only installs
  # silently do nothing.
  local installed="false"
  if [ "$plugin_installed" = "true" ] && [ "$registered" = "true" ]; then
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

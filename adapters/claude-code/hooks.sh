#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Claude Code hook installation for atrium.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
SETTINGS_FILE="${HOME}/.claude/settings.json"

# jq is required for reliable JSON deep-merge
if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# atrium hook marker — used to identify our hooks for clean uninstall/status
atrium_MARKER="ATRIUM_HOOK_MARKER=atrium-runtime-hook"

# Build the hook command string with CLI transport (preferred) and HTTP fallback.
# Usage: build_hook_command <uri> <adapter_name> <event_name> <marker> <cli_path>
# Uses the channel-specific CLI binary path (ATRIUM_MCP_SHIM_PATH) baked at install
# time, with fallback to generic `atrium` on PATH, then HTTP.
build_hook_command() {
  local uri="$1" adapter_name="$2" event_name="$3" marker="$4" cli_path="$5"
  jq -n --arg uri "$uri" --arg adapter "$adapter_name" --arg event "$event_name" --arg marker "$marker" --arg cli "$cli_path" \
    '($marker + "; PAYLOAD=$(cat); CLI=\"" + $cli + "\"; if [ -x \"$CLI\" ]; then \"$CLI\" hook emit " + $event + " --adapter " + $adapter + " --pane-id \"${ATRIUM_PANE_ID:-}\" --json 2>/dev/null || exit 0; else [ -n \"${ATRIUM_HOOK_PORT:-}${ATRIUM_DATA_DIR:-}\" ] || exit 0; DATA_DIR=${ATRIUM_DATA_DIR:-$HOME/.atrium}; PORT=${ATRIUM_HOOK_PORT:-$(cat \"$DATA_DIR/hook-port\" 2>/dev/null)}; [ -n \"$PORT\" ] || exit 0; curl -s -X POST http://127.0.0.1:$PORT/resolve -H \"Content-Type: application/json\" -H \"X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}\" -d \"{\\\"uri\\\": \\\"" + $uri + "\\\", \\\"paneId\\\": \\\"${ATRIUM_PANE_ID:-}\\\", \\\"params\\\": $PAYLOAD}\"; fi")'
}

# Build the hook command template.
# The installed command resolves the active hook port at runtime from the pane's
# injected ATRIUM_HOOK_PORT / ATRIUM_DATA_DIR so stable/dev/beta instances can coexist.
build_session_start_hook() {
  local uri="${ATRIUM_HOOK_URI_SESSION_START:-atrium://hooks/claude-code/session-start}"
  local cli_path="${ATRIUM_MCP_SHIM_PATH:-atrium}"
  local cmd
  cmd="$(build_hook_command "$uri" "claude-code" "session-start" "$atrium_MARKER" "$cli_path")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "startup|resume",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
}

build_session_end_hook() {
  local uri="${ATRIUM_HOOK_URI_SESSION_END:-atrium://hooks/claude-code/session-end}"
  local cli_path="${ATRIUM_MCP_SHIM_PATH:-atrium}"
  local cmd
  cmd="$(build_hook_command "$uri" "claude-code" "session-end" "$atrium_MARKER" "$cli_path")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
}

# Ensure settings file exists with valid JSON
ensure_settings_file() {
  local dir
  dir="$(dirname "$SETTINGS_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
  fi
}

install_mcp_server() {
  local shim_path="${ATRIUM_MCP_SHIM_PATH:-}"
  local data_dir="${ATRIUM_DATA_DIR:-}"
  local channel="${ATRIUM_CHANNEL:-stable}"

  if [ -z "$shim_path" ] || [ -z "$data_dir" ]; then
    return 0
  fi

  if ! command -v claude &>/dev/null; then
    return 0
  fi

  # Channel-specific MCP server name so stable/dev/beta can coexist.
  # Stable uses "atrium", dev uses "atrium-dev", beta uses "atrium-beta".
  local mcp_name="atrium"
  if [ "$channel" != "stable" ]; then
    mcp_name="atrium-${channel}"
  fi

  # Remove existing entry first (idempotent)
  claude mcp remove -s user "$mcp_name" 2>/dev/null || true

  # Add with env var for data dir (name must come before -e due to variadic parsing)
  # The shim_path points to the atrium CLI binary; mcp-serve subcommand starts the MCP server.
  # --pane-id is injected at runtime by Claude Code via ATRIUM_PANE_ID env var.
  claude mcp add -s user "$mcp_name" -e "ATRIUM_DATA_DIR=${data_dir}" -- "$shim_path" mcp-serve 2>/dev/null || true
}

do_install() {
  ensure_settings_file

  local start_hook end_hook
  start_hook="$(build_session_start_hook)"
  end_hook="$(build_session_end_hook)"

  # Deep-merge hooks into existing settings.json
  # Uses jq to:
  # 1. Read existing settings
  # 2. Remove any existing atrium hooks from SessionStart/SessionEnd
  # 3. Append new atrium hooks to the arrays (preserving non-atrium hooks)
  local updated
  updated="$(jq \
    --argjson session_start "$start_hook" \
    --argjson session_end "$end_hook" \
    '
    .hooks = (.hooks // {}) |
    .hooks.SessionStart = (
      [(.hooks.SessionStart // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $session_start
    ) |
    .hooks.SessionEnd = (
      [(.hooks.SessionEnd // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $session_end
    )
    ' "$SETTINGS_FILE")"

  # Atomic write: write hooks to settings.json
  local temp_file="${SETTINGS_FILE}.atrium-tmp"
  echo "$updated" > "$temp_file"
  mv "$temp_file" "$SETTINGS_FILE"

  # Register atrium MCP server via claude CLI
  install_mcp_server

  echo '{"subcommand": "install", "installed": true}'
  exit 0
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    exit 0
  fi

  # Remove only the atrium-specific hook entries (SessionStart and SessionEnd
  # that contain our hook-port marker). Filter out hooks whose command references
  # atrium/hook-port, then prune empty arrays and the hooks object if empty.
  local updated
  updated="$(jq '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(select(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))
          | select(.hooks | length > 0)
        )
        | select(.value | length > 0)
      )
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS_FILE")"

  local temp_file="${SETTINGS_FILE}.atrium-tmp"
  echo "$updated" > "$temp_file"
  mv "$temp_file" "$SETTINGS_FILE"

  # Remove atrium MCP server (all channel variants)
  if command -v claude &>/dev/null; then
    claude mcp remove -s user atrium 2>/dev/null || true
    claude mcp remove -s user atrium-dev 2>/dev/null || true
    claude mcp remove -s user atrium-beta 2>/dev/null || true
  fi

  echo '{"subcommand": "uninstall", "uninstalled": true}'
  exit 0
}

do_status() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false, "mcpConfigured": false}'
    exit 0
  fi

  # Check if our hooks are present by looking for the atrium marker
  local has_hooks
  has_hooks="$(jq '
    ((.hooks.SessionStart // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
    and
    ((.hooks.SessionEnd // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
  ' "$SETTINGS_FILE" 2>/dev/null)" || has_hooks="false"

  # Check if MCP server config is present
  local has_mcp="false"
  if command -v claude &>/dev/null && claude mcp get atrium &>/dev/null; then
    has_mcp="true"
  fi

  echo "{\"subcommand\": \"status\", \"installed\": ${has_hooks}, \"mcpConfigured\": ${has_mcp}}"
  exit 0
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

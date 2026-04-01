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

# atrium hook marker — used to identify our hooks for clean uninstall
atrium_MARKER="atrium/hook-port"

# Build the hook command template.
# Prefers ATRIUM_HOOK_PORT env var (set per-PTY, routes to the correct instance)
# with fallback to ~/.atrium/hook-port file for backward compatibility.
build_session_start_hook() {
  cat <<'HOOKJSON'
[{
  "matcher": "startup|resume",
  "hooks": [{
    "type": "command",
    "command": "PORT=${ATRIUM_HOOK_PORT:-$(cat ~/.atrium/hook-port 2>/dev/null)} && [ -n \"$PORT\" ] && curl -s -X POST http://127.0.0.1:$PORT/api/adapter/claude-code/session-start -H 'Content-Type: application/json' -H \"X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}\" -d \"$(cat)\"",
    "timeout": 5
  }]
}]
HOOKJSON
}

build_session_end_hook() {
  cat <<'HOOKJSON'
[{
  "matcher": "*",
  "hooks": [{
    "type": "command",
    "command": "PORT=${ATRIUM_HOOK_PORT:-$(cat ~/.atrium/hook-port 2>/dev/null)} && [ -n \"$PORT\" ] && curl -s -X POST http://127.0.0.1:$PORT/api/adapter/claude-code/session-end -H 'Content-Type: application/json' -H \"X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}\" -d \"$(cat)\"",
    "timeout": 5
  }]
}]
HOOKJSON
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
      [(.hooks.SessionStart // [])[] | select(.hooks | all(.command | test("atrium/hook-port|aiterm/hook-port") | not))]
      + $session_start
    ) |
    .hooks.SessionEnd = (
      [(.hooks.SessionEnd // [])[] | select(.hooks | all(.command | test("atrium/hook-port|aiterm/hook-port") | not))]
      + $session_end
    )
    ' "$SETTINGS_FILE")"

  # Atomic write: write to temp file, then move
  local temp_file="${SETTINGS_FILE}.atrium-tmp"
  echo "$updated" > "$temp_file"
  mv "$temp_file" "$SETTINGS_FILE"

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
          .hooks |= map(select(.command | test("atrium/hook-port") | not))
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

  echo '{"subcommand": "uninstall", "uninstalled": true}'
  exit 0
}

do_status() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false}'
    exit 0
  fi

  # Check if our hooks are present by looking for the atrium marker
  local has_hooks
  has_hooks="$(jq '
    ((.hooks.SessionStart // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port")))
    and
    ((.hooks.SessionEnd // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port")))
  ' "$SETTINGS_FILE" 2>/dev/null)" || has_hooks="false"

  echo "{\"subcommand\": \"status\", \"installed\": ${has_hooks}}"
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

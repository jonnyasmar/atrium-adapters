#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Codex hook installation for atrium.
# Codex hooks require TWO config changes:
#   1. Enable codex_hooks = true in ~/.codex/config.toml (feature flag)
#   2. Write hook definition in ~/.codex/hooks.json under hooks.SessionStart / hooks.SessionEnd
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
CONFIG_TOML="${HOME}/.codex/config.toml"
HOOKS_JSON="${HOME}/.codex/hooks.json"

# jq is required for reliable JSON manipulation
if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# atrium hook marker — used to identify our hooks for clean uninstall
atrium_MARKER="atrium/hook-port"

# Build the SessionStart hook command template.
# Reads port from ~/.atrium/hook-port at execution time (not install time).
build_session_start_hook() {
  cat <<'HOOKJSON'
[{
  "matcher": "startup|resume",
  "hooks": [{
    "type": "command",
    "command": "PORT=$(cat ~/.atrium/hook-port 2>/dev/null) && [ -n \"$PORT\" ] && curl -s -X POST http://127.0.0.1:$PORT/api/adapter/codex/session-start -H 'Content-Type: application/json' -d \"$(cat)\"",
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
    "command": "PORT=$(cat ~/.atrium/hook-port 2>/dev/null) && [ -n \"$PORT\" ] && curl -s -X POST http://127.0.0.1:$PORT/api/adapter/codex/session-end -H 'Content-Type: application/json' -d \"$(cat)\"",
    "timeout": 5
  }]
}]
HOOKJSON
}

# Ensure the ~/.codex directory exists
ensure_codex_dir() {
  local dir
  dir="$(dirname "$CONFIG_TOML")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
}

# Enable the codex_hooks feature flag in config.toml
enable_hooks_feature() {
  ensure_codex_dir

  if [ ! -f "$CONFIG_TOML" ]; then
    # Create config.toml with the feature flag
    printf '[features]\ncodex_hooks = true\n' > "$CONFIG_TOML"
    return 0
  fi

  # Check if codex_hooks is already set to true
  if grep -qE '^\s*codex_hooks\s*=\s*true' "$CONFIG_TOML" 2>/dev/null; then
    return 0
  fi

  # Check if [features] section exists
  if grep -qE '^\[features\]' "$CONFIG_TOML" 2>/dev/null; then
    # Check if codex_hooks line exists (but not set to true)
    if grep -qE '^\s*codex_hooks\s*=' "$CONFIG_TOML" 2>/dev/null; then
      # Replace existing value
      local temp_file="${CONFIG_TOML}.atrium-tmp"
      sed 's/^\([[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*\).*/\1true/' "$CONFIG_TOML" > "$temp_file"
      mv "$temp_file" "$CONFIG_TOML"
    else
      # Append codex_hooks under [features] section
      local temp_file="${CONFIG_TOML}.atrium-tmp"
      sed '/^\[features\]/a\
codex_hooks = true' "$CONFIG_TOML" > "$temp_file"
      mv "$temp_file" "$CONFIG_TOML"
    fi
  else
    # Append [features] section with the flag
    local temp_file="${CONFIG_TOML}.atrium-tmp"
    printf '%s\n\n[features]\ncodex_hooks = true\n' "$(cat "$CONFIG_TOML")" > "$temp_file"
    mv "$temp_file" "$CONFIG_TOML"
  fi
}

# Disable the codex_hooks feature flag in config.toml
disable_hooks_feature() {
  if [ ! -f "$CONFIG_TOML" ]; then
    return 0
  fi

  if grep -qE '^\s*codex_hooks\s*=' "$CONFIG_TOML" 2>/dev/null; then
    local temp_file="${CONFIG_TOML}.atrium-tmp"
    sed 's/^\([[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*\).*/\1false/' "$CONFIG_TOML" > "$temp_file"
    mv "$temp_file" "$CONFIG_TOML"
  fi
}

# Ensure hooks.json exists with valid JSON
ensure_hooks_file() {
  ensure_codex_dir
  if [ ! -f "$HOOKS_JSON" ]; then
    echo '{}' > "$HOOKS_JSON"
  fi
}

do_install() {
  # Step 1: Enable feature flag in config.toml
  enable_hooks_feature

  # Step 2: Write hooks into hooks.json under the "hooks" wrapper key
  ensure_hooks_file

  local start_hook end_hook
  start_hook="$(build_session_start_hook)"
  end_hook="$(build_session_end_hook)"

  # Deep-merge hooks into existing hooks.json.
  # Codex expects: { "hooks": { "SessionStart": [...], "SessionEnd": [...] } }
  # Remove any existing atrium hooks first, then add new ones.
  # Also clean up legacy root-level and on_user_prompt keys.
  local updated
  updated="$(jq \
    --argjson session_start "$start_hook" \
    --argjson session_end "$end_hook" \
    '
    .hooks = (.hooks // {}) |
    .hooks.SessionStart = (
      [(.hooks.SessionStart // [])[] | select(.hooks | all(.command | test("atrium/hook-port") | not))]
      + $session_start
    ) |
    .hooks.SessionEnd = (
      [(.hooks.SessionEnd // [])[] | select(.hooks | all(.command | test("atrium/hook-port") | not))]
      + $session_end
    ) |
    # Clean up legacy root-level keys from previous versions
    if .SessionStart then del(.SessionStart) else . end |
    if .SessionEnd then del(.SessionEnd) else . end |
    if .on_user_prompt then del(.on_user_prompt) else . end
    ' "$HOOKS_JSON")"

  # Atomic write: write to temp file, then move
  local temp_file="${HOOKS_JSON}.atrium-tmp"
  echo "$updated" > "$temp_file"
  mv "$temp_file" "$HOOKS_JSON"

  echo '{"subcommand": "install", "installed": true}'
  exit 0
}

do_uninstall() {
  # Step 1: Disable feature flag in config.toml
  disable_hooks_feature

  # Step 2: Remove atrium hooks from hooks.json
  if [ ! -f "$HOOKS_JSON" ]; then
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    exit 0
  fi

  local updated
  updated="$(jq '
    # Remove atrium hooks from hooks.SessionStart / hooks.SessionEnd
    if .hooks then
      .hooks |= with_entries(
        .value |= [.[] |
          .hooks |= [.[] | select(.command | test("atrium/hook-port") | not)]
          | select(.hooks | length > 0)
        ] | select(length > 0)
      )
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end |
    # Clean up legacy root-level keys
    if .SessionStart then del(.SessionStart) else . end |
    if .SessionEnd then del(.SessionEnd) else . end |
    if .on_user_prompt then del(.on_user_prompt) else . end
  ' "$HOOKS_JSON")"

  local temp_file="${HOOKS_JSON}.atrium-tmp"
  echo "$updated" > "$temp_file"
  mv "$temp_file" "$HOOKS_JSON"

  echo '{"subcommand": "uninstall", "uninstalled": true}'
  exit 0
}

do_status() {
  # Check BOTH conditions:
  # 1. config.toml has codex_hooks = true
  # 2. hooks.json has the atrium hook command under hooks.SessionStart

  local has_feature=false
  if [ -f "$CONFIG_TOML" ] && grep -qE '^\s*codex_hooks\s*=\s*true' "$CONFIG_TOML" 2>/dev/null; then
    has_feature=true
  fi

  local has_hook=false
  if [ -f "$HOOKS_JSON" ]; then
    has_hook="$(jq '
      ((.hooks.SessionStart // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port")))
      and
      ((.hooks.SessionEnd // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port")))
    ' "$HOOKS_JSON" 2>/dev/null)" || has_hook="false"
  fi

  # Both must be true for hooks to be considered installed
  if [ "$has_feature" = "true" ] && [ "$has_hook" = "true" ]; then
    echo '{"subcommand": "status", "installed": true}'
  else
    echo '{"subcommand": "status", "installed": false}'
  fi
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

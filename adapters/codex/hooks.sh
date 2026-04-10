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

# atrium hook marker — used to identify our hooks for clean uninstall/status
atrium_MARKER="ATRIUM_HOOK_MARKER=atrium-runtime-hook"

# Build the hook command string with CLI transport (preferred) and HTTP fallback.
# Usage: build_hook_command <uri> <adapter_name> <event_name> <marker>
# Uses ATRIUM_CLI_PATH env var at runtime for environment-aware CLI resolution.
build_hook_command() {
  local uri="$1" adapter_name="$2" event_name="$3" marker="$4"
  jq -n --arg uri "$uri" --arg adapter "$adapter_name" --arg event "$event_name" --arg marker "$marker" \
    '($marker + "; PAYLOAD=$(cat); CLI=\"${ATRIUM_CLI_PATH:-atrium}\"; if [ -x \"$CLI\" ]; then echo \"$PAYLOAD\" | \"$CLI\" hook emit " + $event + " --adapter " + $adapter + " --pane-id \"${ATRIUM_PANE_ID:-}\" --json >/dev/null 2>/dev/null || exit 0; else [ -n \"${ATRIUM_HOOK_PORT:-}${ATRIUM_DATA_DIR:-}\" ] || exit 0; DATA_DIR=${ATRIUM_DATA_DIR:-$HOME/.atrium}; PORT=${ATRIUM_HOOK_PORT:-$(cat \"$DATA_DIR/hook-port\" 2>/dev/null)}; [ -n \"$PORT\" ] || exit 0; curl -s -X POST http://127.0.0.1:$PORT/resolve -H \"Content-Type: application/json\" -H \"X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}\" -d \"{\\\"uri\\\": \\\"" + $uri + "\\\", \\\"paneId\\\": \\\"${ATRIUM_PANE_ID:-}\\\", \\\"params\\\": $PAYLOAD}\" >/dev/null; fi")'
}

install_context_file() {
  local source_file
  source_file="$(cd "$(dirname "$0")" && pwd)/../shared/atrium-context.txt"
  local dest_dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}"

  if [ ! -f "$source_file" ]; then
    return 0
  fi

  mkdir -p "$dest_dir"
  cp "$source_file" "$dest_dir/agent-context.txt"
}

# Build the SessionStart hook command template.
# The installed command resolves the active hook port at runtime from the pane's
# injected ATRIUM_HOOK_PORT / ATRIUM_DATA_DIR so stable/dev/beta instances can coexist.
build_session_start_hook() {
  local uri="${ATRIUM_HOOK_URI_SESSION_START:-atrium://hooks/codex/session-start}"
  local cmd
  cmd="$(build_hook_command "$uri" "codex" "session-start" "$atrium_MARKER")"
  local ctx_cmd_str="${atrium_MARKER}; [ -n \"\${ATRIUM:-}\" ] && cat \"\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/agent-context.txt\" 2>/dev/null || true"
  jq -n --argjson cmd "$cmd" --arg ctx_cmd "$ctx_cmd_str" '[{
    "matcher": "startup|resume",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }, {
    "matcher": "startup|resume",
    "hooks": [{
      "type": "command",
      "command": $ctx_cmd,
      "timeout": 5
    }]
  }]'
}

build_session_end_hook() {
  local uri="${ATRIUM_HOOK_URI_SESSION_END:-atrium://hooks/codex/session-end}"
  local cmd
  cmd="$(build_hook_command "$uri" "codex" "session-end" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
}

build_pre_tool_use_hook() {
  local uri="${ATRIUM_HOOK_URI_PRE_TOOL_USE:-atrium://hooks/codex/pre-tool-use}"
  local cmd
  cmd="$(build_hook_command "$uri" "codex" "pre-tool-use" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": ".*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
}

build_post_tool_use_hook() {
  local uri="${ATRIUM_HOOK_URI_POST_TOOL_USE:-atrium://hooks/codex/post-tool-use}"
  local cmd
  cmd="$(build_hook_command "$uri" "codex" "post-tool-use" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": ".*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
}

build_stop_hook() {
  local uri="${ATRIUM_HOOK_URI_STOP:-atrium://hooks/codex/stop}"
  local cmd
  cmd="$(build_hook_command "$uri" "codex" "stop" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": ".*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
}

build_user_prompt_submit_hook() {
  local uri="${ATRIUM_HOOK_URI_USER_PROMPT_SUBMIT:-atrium://hooks/codex/user-prompt-submit}"
  local cmd
  cmd="$(build_hook_command "$uri" "codex" "user-prompt-submit" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": ".*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5
    }]
  }]'
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

remove_atrium_mcp_config() {
  if [ ! -f "$CONFIG_TOML" ]; then
    return 0
  fi

  local temp_file="${CONFIG_TOML}.atrium-tmp"
  awk '
    BEGIN { skip = 0 }
    /^\[mcp_servers\.atrium(\.env)?\]$/ {
      skip = 1
      next
    }
    /^\[/ {
      if (skip) {
        skip = 0
      }
    }
    !skip { print }
  ' "$CONFIG_TOML" > "$temp_file"
  mv "$temp_file" "$CONFIG_TOML"
}

do_install() {
  # Step 1: Enable feature flag in config.toml
  enable_hooks_feature

  # Step 2: Write hooks into hooks.json under the "hooks" wrapper key
  ensure_hooks_file

  local start_hook end_hook pre_tool_use_hook post_tool_use_hook stop_hook user_prompt_submit_hook
  start_hook="$(build_session_start_hook)"
  end_hook="$(build_session_end_hook)"
  pre_tool_use_hook="$(build_pre_tool_use_hook)"
  post_tool_use_hook="$(build_post_tool_use_hook)"
  stop_hook="$(build_stop_hook)"
  user_prompt_submit_hook="$(build_user_prompt_submit_hook)"

  # Deep-merge hooks into existing hooks.json.
  # Codex expects: { "hooks": { "SessionStart": [...], "SessionEnd": [...], ... } }
  # Remove any existing atrium hooks first, then add new ones.
  # Single jq invocation with 6 --argjson arguments, single atomic write.
  # Also clean up legacy root-level and on_user_prompt keys.
  local updated
  updated="$(jq \
    --argjson session_start "$start_hook" \
    --argjson session_end "$end_hook" \
    --argjson pre_tool_use "$pre_tool_use_hook" \
    --argjson post_tool_use "$post_tool_use_hook" \
    --argjson stop "$stop_hook" \
    --argjson user_prompt_submit "$user_prompt_submit_hook" \
    '
    .hooks = (.hooks // {}) |
    .hooks.SessionStart = (
      [(.hooks.SessionStart // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $session_start
    ) |
    .hooks.SessionEnd = (
      [(.hooks.SessionEnd // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $session_end
    ) |
    .hooks.PreToolUse = (
      [(.hooks.PreToolUse // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $pre_tool_use
    ) |
    .hooks.PostToolUse = (
      [(.hooks.PostToolUse // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $post_tool_use
    ) |
    .hooks.Stop = (
      [(.hooks.Stop // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $stop
    ) |
    .hooks.UserPromptSubmit = (
      [(.hooks.UserPromptSubmit // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $user_prompt_submit
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

  # Step 3: Remove legacy MCP server if present (replaced by CLI skill)
  uninstall_mcp_server

  # Step 4: Install atrium CLI skill for Codex
  install_skill

  # Step 5: Install agent context file for SessionStart injection
  install_context_file

  echo '{"subcommand": "install", "installed": true}'
  exit 0
}

install_skill() {
  # Install the atrium CLI skill to ~/.codex/skills/atrium/
  local skill_dir="${HOME}/.codex/skills/atrium"
  local source_dir
  source_dir="$(cd "$(dirname "$0")" && pwd)/skills/atrium"

  if [ ! -f "${source_dir}/SKILL.md" ]; then
    return 0
  fi

  mkdir -p "$skill_dir"
  cp "${source_dir}/SKILL.md" "${skill_dir}/SKILL.md"
}

uninstall_skill() {
  local skill_dir="${HOME}/.codex/skills/atrium"
  if [ -d "$skill_dir" ]; then
    rm -rf "$skill_dir"
  fi
}

uninstall_mcp_server() {
  # Remove legacy MCP server registration if present
  if command -v codex &>/dev/null; then
    codex mcp remove atrium 2>/dev/null || true
  fi
  remove_atrium_mcp_config
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
    # Remove atrium hooks from all event categories under .hooks (generic filter)
    if .hooks then
      .hooks |= with_entries(
        .value |= [.[] |
          .hooks |= [.[] | select(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not)]
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

  # Step 3: Remove atrium MCP server
  uninstall_mcp_server

  # Step 4: Remove atrium CLI skill
  uninstall_skill

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
      ((.hooks.SessionStart // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
      and
      ((.hooks.SessionEnd // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
    ' "$HOOKS_JSON" 2>/dev/null)" || has_hook="false"
  fi

  # Check if activity hooks are present (at least one of PreToolUse, PostToolUse, Stop, UserPromptSubmit)
  local has_activity_hooks=false
  if [ -f "$HOOKS_JSON" ]; then
    has_activity_hooks="$(jq '
      ((.hooks.PreToolUse // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
      or
      ((.hooks.PostToolUse // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
      or
      ((.hooks.Stop // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
      or
      ((.hooks.UserPromptSubmit // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
    ' "$HOOKS_JSON" 2>/dev/null)" || has_activity_hooks="false"
  fi

  # Both feature flag + session hooks must be true for hooks to be considered installed
  local installed=false
  if [ "$has_feature" = "true" ] && [ "$has_hook" = "true" ]; then
    installed=true
  fi

  # Check if skill is installed
  local has_skill="false"
  if [ -f "${HOME}/.codex/skills/atrium/SKILL.md" ]; then
    has_skill="true"
  fi

  echo "{\"subcommand\": \"status\", \"installed\": ${installed}, \"activityHooks\": ${has_activity_hooks}, \"skillInstalled\": ${has_skill}}"
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

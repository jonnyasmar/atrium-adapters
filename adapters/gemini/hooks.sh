#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Gemini CLI hook installation for atrium.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
SETTINGS_FILE="${HOME}/.gemini/settings.json"

# jq is required for reliable JSON deep-merge
if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# atrium hook marker — used to identify our hooks for clean uninstall/status
atrium_MARKER="ATRIUM_HOOK_MARKER=atrium-runtime-hook"

# Build the hook command string with CLI transport (preferred) and HTTP fallback.
build_hook_command() {
  local uri="$1" adapter_name="$2" event_name="$3" marker="$4"
  # Gemini sanitizes hook environments, stripping ATRIUM_* vars.
  # We bake the data dir path at install time so hooks work without env vars.
  # Detect dev vs stable from the current data dir.
  local atrium_dir_name
  atrium_dir_name="$(basename "$(crate::paths::atrium_dir_name 2>/dev/null || echo ".atrium")")"
  # Simpler: check if we're installed under .atrium-dev
  if [ -d "${HOME}/.atrium-dev/adapters/gemini" ]; then
    atrium_dir_name=".atrium-dev"
  else
    atrium_dir_name=".atrium"
  fi
  jq -n --arg uri "$uri" --arg adapter "$adapter_name" --arg event "$event_name" --arg marker "$marker" --arg atrium_dir "$atrium_dir_name" \
    '($marker + "; PAYLOAD=$(cat); CLI=\"${ATRIUM_CLI_PATH:-$HOME/" + $atrium_dir + "/bin/" + (if $atrium_dir == ".atrium-dev" then "atrium-dev" else "atrium" end) + "}\"; if [ -x \"$CLI\" ]; then echo \"$PAYLOAD\" | \"$CLI\" hook emit " + $event + " --adapter " + $adapter + " --pane-id \"${ATRIUM_PANE_ID:-}\" --json 2>/dev/null || exit 0; else DATA_DIR=\"$HOME/" + $atrium_dir + "\"; PORT=${ATRIUM_HOOK_PORT:-$(cat \"$DATA_DIR/hook-port\" 2>/dev/null)}; [ -n \"$PORT\" ] || exit 0; curl -s -X POST http://127.0.0.1:$PORT/resolve -H \"Content-Type: application/json\" -H \"X-Atrium-Pane-Id: ${ATRIUM_PANE_ID:-}\" -d \"{\\\"uri\\\": \\\"" + $uri + "\\\", \\\"paneId\\\": \\\"${ATRIUM_PANE_ID:-}\\\", \\\"params\\\": $PAYLOAD}\"; fi")'
}

build_session_start_hook() {
  local uri="${ATRIUM_HOOK_URI_SESSION_START:-atrium://hooks/gemini/session-start}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "session-start" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "startup",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
    }]
  }]'
}

build_session_end_hook() {
  local uri="${ATRIUM_HOOK_URI_SESSION_END:-atrium://hooks/gemini/session-end}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "session-end" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
    }]
  }]'
}

build_before_agent_hook() {
  local uri="${ATRIUM_HOOK_URI_USER_PROMPT_SUBMIT:-atrium://hooks/gemini/user-prompt-submit}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "user-prompt-submit" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
    }]
  }]'
}

build_before_tool_hook() {
  local uri="${ATRIUM_HOOK_URI_PRE_TOOL_USE:-atrium://hooks/gemini/pre-tool-use}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "pre-tool-use" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": ".*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
    }]
  }]'
}

build_after_tool_hook() {
  local uri="${ATRIUM_HOOK_URI_POST_TOOL_USE:-atrium://hooks/gemini/post-tool-use}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "post-tool-use" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": ".*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
    }]
  }]'
}

build_after_agent_hook() {
  local uri="${ATRIUM_HOOK_URI_STOP:-atrium://hooks/gemini/stop}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "stop" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
    }]
  }]'
}

build_notification_hook() {
  local uri="${ATRIUM_HOOK_URI_NOTIFICATION:-atrium://hooks/gemini/notification}"
  local cmd
  cmd="$(build_hook_command "$uri" "gemini" "notification" "$atrium_MARKER")"
  jq -n --argjson cmd "$cmd" '[{
    "matcher": "*",
    "hooks": [{
      "type": "command",
      "command": $cmd,
      "timeout": 5000
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

do_install() {
  ensure_settings_file

  local start_hook end_hook before_agent_hook before_tool_hook after_tool_hook after_agent_hook notification_hook
  start_hook="$(build_session_start_hook)"
  end_hook="$(build_session_end_hook)"
  before_agent_hook="$(build_before_agent_hook)"
  before_tool_hook="$(build_before_tool_hook)"
  after_tool_hook="$(build_after_tool_hook)"
  after_agent_hook="$(build_after_agent_hook)"
  notification_hook="$(build_notification_hook)"

  # Deep-merge hooks into existing settings.json
  # Keys are Gemini's PascalCase event names; commands emit atrium's kebab-case names.
  local updated
  updated="$(jq \
    --argjson session_start "$start_hook" \
    --argjson session_end "$end_hook" \
    --argjson before_agent "$before_agent_hook" \
    --argjson before_tool "$before_tool_hook" \
    --argjson after_tool "$after_tool_hook" \
    --argjson after_agent "$after_agent_hook" \
    --argjson notification "$notification_hook" \
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
    .hooks.BeforeAgent = (
      [(.hooks.BeforeAgent // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $before_agent
    ) |
    .hooks.BeforeTool = (
      [(.hooks.BeforeTool // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $before_tool
    ) |
    .hooks.AfterTool = (
      [(.hooks.AfterTool // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $after_tool
    ) |
    .hooks.AfterAgent = (
      [(.hooks.AfterAgent // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $after_agent
    ) |
    .hooks.Notification = (
      [(.hooks.Notification // [])[] | select(.hooks | all(.command | test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit") | not))]
      + $notification
    )
    ' "$SETTINGS_FILE")"

  # Atomic write
  local temp_file="${SETTINGS_FILE}.atrium-tmp"
  echo "$updated" > "$temp_file"
  mv "$temp_file" "$SETTINGS_FILE"

  # Install atrium CLI skill for Gemini
  install_skill

  echo '{"subcommand": "install", "installed": true}'
  exit 0
}

install_skill() {
  # Install the atrium CLI skill to ~/.gemini/skills/atrium/
  local skill_dir="${HOME}/.gemini/skills/atrium"
  local source_dir
  source_dir="$(cd "$(dirname "$0")" && pwd)/skills/atrium"

  if [ ! -f "${source_dir}/SKILL.md" ]; then
    return 0
  fi

  mkdir -p "$skill_dir"
  cp "${source_dir}/SKILL.md" "${skill_dir}/SKILL.md"
}

uninstall_skill() {
  local skill_dir="${HOME}/.gemini/skills/atrium"
  if [ -d "$skill_dir" ]; then
    rm -rf "$skill_dir"
  fi
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    uninstall_skill
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    exit 0
  fi

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

  # Remove atrium CLI skill
  uninstall_skill

  echo '{"subcommand": "uninstall", "uninstalled": true}'
  exit 0
}

do_status() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false, "skillInstalled": false}'
    exit 0
  fi

  local has_hooks
  has_hooks="$(jq '
    ((.hooks.SessionStart // []) | [.[].hooks[]?.command] | any(test("atrium/hook-port|atrium-runtime-hook|/resolve|atrium hook emit")))
  ' "$SETTINGS_FILE" 2>/dev/null || echo "false")"

  # Check if skill is installed
  local has_skill="false"
  if [ -f "${HOME}/.gemini/skills/atrium/SKILL.md" ]; then
    has_skill="true"
  fi

  echo "{\"subcommand\": \"status\", \"installed\": ${has_hooks}, \"skillInstalled\": ${has_skill}}"
  exit 0
}

case "$SUBCOMMAND" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)
    echo "{\"error\": \"Unknown subcommand: ${SUBCOMMAND}\"}" >&2
    exit 1
    ;;
esac

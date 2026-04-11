#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Codex hook installation for atrium.
# Codex hooks require TWO config changes:
#   1. Enable `codex_hooks = true` in ~/.codex/config.toml (feature flag)
#   2. Write hook definitions into ~/.codex/hooks.json under .hooks.<Event>
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
CONFIG_TOML="${HOME}/.codex/config.toml"
HOOKS_JSON="${HOME}/.codex/hooks.json"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Marker embedded as the first statement of every atrium-owned hook command.
# The regex matches both current and legacy command shapes so install and
# uninstall can still clean up entries written by prior releases.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|atrium/hook-port|/resolve'

# Event table: kebab-case event name, Codex settings key, matcher.
EVENTS=$'session-start\tSessionStart\tstartup|resume
session-end\tSessionEnd\t*
pre-tool-use\tPreToolUse\t.*
post-tool-use\tPostToolUse\t.*
stop\tStop\t.*
user-prompt-submit\tUserPromptSubmit\t.*'

# Build the hook command string for a given event. Resolved at hook-fire time
# against the pane's injected env vars so stable/dev/beta can coexist. Trails
# with `exit 0` so any CLI failure never breaks the agent session.
build_hook_command() {
  local event="$1"
  printf '%s; "${ATRIUM_CLI_PATH:-atrium}" hook emit %s --adapter codex --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$event"
}

# Assemble the full hooks object by walking the event table, then append the
# codex-specific context-inject entry whose stdout becomes session context.
build_all_hooks() {
  local hooks='{}'
  local event key matcher cmd entry
  while IFS=$'\t' read -r event key matcher; do
    [ -n "${event:-}" ] || continue
    cmd="$(build_hook_command "$event")"
    entry="$(jq -n --arg matcher "$matcher" --arg cmd "$cmd" \
      '[{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
    hooks="$(jq --arg key "$key" --argjson entry "$entry" \
      '.[$key] = (.[$key] // []) + $entry' <<< "$hooks")"
  done <<< "$EVENTS"

  # Second SessionStart matcher that cats the agent-context file. Stdout is
  # consumed as session context by Codex, same as the Claude Code flow.
  local ctx_cmd ctx_entry
  ctx_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && cat "${ATRIUM_DATA_DIR:-$HOME/.atrium}/agent-context.txt" 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX")"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"

  printf '%s' "$hooks"
}

ensure_codex_dir() {
  local dir
  dir="$(dirname "$CONFIG_TOML")"
  [ -d "$dir" ] || mkdir -p "$dir"
}

ensure_hooks_file() {
  ensure_codex_dir
  [ -f "$HOOKS_JSON" ] || echo '{}' > "$HOOKS_JSON"
}

# Enable the codex_hooks feature flag in config.toml. Handles three cases:
# missing file, existing [features] section, and no [features] section.
enable_hooks_feature() {
  ensure_codex_dir

  if [ ! -f "$CONFIG_TOML" ]; then
    printf '[features]\ncodex_hooks = true\n' > "$CONFIG_TOML"
    return 0
  fi

  if grep -qE '^\s*codex_hooks\s*=\s*true' "$CONFIG_TOML" 2>/dev/null; then
    return 0
  fi

  local tmp="${CONFIG_TOML}.atrium-tmp"
  if grep -qE '^\[features\]' "$CONFIG_TOML" 2>/dev/null; then
    if grep -qE '^\s*codex_hooks\s*=' "$CONFIG_TOML" 2>/dev/null; then
      sed 's/^\([[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*\).*/\1true/' "$CONFIG_TOML" > "$tmp"
    else
      sed '/^\[features\]/a\
codex_hooks = true' "$CONFIG_TOML" > "$tmp"
    fi
  else
    printf '%s\n\n[features]\ncodex_hooks = true\n' "$(cat "$CONFIG_TOML")" > "$tmp"
  fi
  mv "$tmp" "$CONFIG_TOML"
}

disable_hooks_feature() {
  [ -f "$CONFIG_TOML" ] || return 0
  if grep -qE '^\s*codex_hooks\s*=' "$CONFIG_TOML" 2>/dev/null; then
    local tmp="${CONFIG_TOML}.atrium-tmp"
    sed 's/^\([[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*\).*/\1false/' "$CONFIG_TOML" > "$tmp"
    mv "$tmp" "$CONFIG_TOML"
  fi
}

# Strip [mcp_servers.atrium] / [mcp_servers.atrium.env] blocks from config.toml.
# Legacy cleanup from when atrium shipped an MCP server instead of the CLI skill.
remove_atrium_mcp_config() {
  [ -f "$CONFIG_TOML" ] || return 0
  local tmp="${CONFIG_TOML}.atrium-tmp"
  awk '
    BEGIN { skip = 0 }
    /^\[mcp_servers\.atrium(\.env)?\]$/ { skip = 1; next }
    /^\[/ { if (skip) skip = 0 }
    !skip { print }
  ' "$CONFIG_TOML" > "$tmp"
  mv "$tmp" "$CONFIG_TOML"
}

install_context_file() {
  local source_file
  source_file="$(cd "$(dirname "$0")" && pwd)/../shared/atrium-context.txt"
  local dest_dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}"
  [ -f "$source_file" ] || return 0
  mkdir -p "$dest_dir"
  cp "$source_file" "$dest_dir/agent-context.txt"
}

uninstall_mcp_server() {
  if command -v codex &>/dev/null; then
    codex mcp remove atrium 2>/dev/null || true
  fi
  remove_atrium_mcp_config
}

has_atrium_hooks_in() {
  local keys_json
  keys_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -r \
    --argjson keys "$keys_json" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '[$keys[] as $k | (.hooks[$k] // [])[] | .hooks[]?.command] | any(test($marker))' \
    "$HOOKS_JSON" 2>/dev/null || echo "false"
}

do_install() {
  enable_hooks_feature
  ensure_hooks_file

  local new_hooks
  new_hooks="$(build_all_hooks)"

  # Deep-merge atrium hooks under the .hooks wrapper. Also strip legacy
  # root-level SessionStart/SessionEnd/on_user_prompt keys that older
  # releases wrote before the wrapper was introduced.
  local updated
  updated="$(jq \
    --argjson new_hooks "$new_hooks" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '
    .hooks = (.hooks // {}) |
    reduce ($new_hooks | keys_unsorted[]) as $k (.;
      .hooks[$k] = (
        [(.hooks[$k] // [])[] | select(.hooks | all(.command | test($marker) | not))]
        + $new_hooks[$k]
      )
    )
    | del(.SessionStart, .SessionEnd, .on_user_prompt)
    ' "$HOOKS_JSON")"

  local tmp="${HOOKS_JSON}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_JSON"

  uninstall_mcp_server
  install_context_file

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  disable_hooks_feature

  if [ ! -f "$HOOKS_JSON" ]; then
    uninstall_mcp_server
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    return
  fi

  local updated
  updated="$(jq \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(select(.command | test($marker) | not))
          | select(.hooks | length > 0)
        )
        | select(.value | length > 0)
      )
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
    | del(.SessionStart, .SessionEnd, .on_user_prompt)
    ' "$HOOKS_JSON")"

  local tmp="${HOOKS_JSON}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_JSON"

  uninstall_mcp_server

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  # Session is installed iff the feature flag is enabled AND both
  # SessionStart and SessionEnd carry atrium hooks.
  local has_feature=false
  if [ -f "$CONFIG_TOML" ] && grep -qE '^\s*codex_hooks\s*=\s*true' "$CONFIG_TOML" 2>/dev/null; then
    has_feature=true
  fi

  local session="false" activity="false"
  if [ -f "$HOOKS_JSON" ]; then
    local start end
    start="$(has_atrium_hooks_in SessionStart)"
    end="$(has_atrium_hooks_in SessionEnd)"
    if [ "$start" = "true" ] && [ "$end" = "true" ]; then
      session="true"
    fi
    activity="$(has_atrium_hooks_in PreToolUse PostToolUse Stop UserPromptSubmit)"
  fi

  local installed="false"
  if [ "$has_feature" = "true" ] && [ "$session" = "true" ]; then
    installed="true"
  fi

  echo "{\"subcommand\": \"status\", \"installed\": ${installed}, \"activityHooks\": ${activity}}"
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

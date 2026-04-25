#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Claude Code hook installation for atrium.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
SETTINGS_FILE="${HOME}/.claude/settings.json"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Marker embedded as the first statement of every atrium-owned hook command.
# The regex below is used by install/uninstall/status to identify hooks we own,
# including legacy command shapes from prior releases. Add legacy alternates
# when bumping the command format; prune once old releases age out.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|atrium/hook-port|/resolve'

# Event table: kebab-case event name, Claude settings key, matcher.
# Each event becomes one hook entry in the corresponding settings.json key.
EVENTS=$'session-start\tSessionStart\tstartup|resume
session-end\tSessionEnd\t*
pre-tool-use\tPreToolUse\t.*
post-tool-use\tPostToolUse\t.*
stop\tStop\t.*
notification\tNotification\t.*
user-prompt-submit\tUserPromptSubmit\t.*
permission-request\tPermissionRequest\t.*
task-created\tTaskCreated\t.*
task-completed\tTaskCompleted\t.*
subagent-start\tSubagentStart\t.*
subagent-stop\tSubagentStop\t.*
stop-failure\tStopFailure\t.*'

# Build the hook command string for a given event. Resolved at hook-fire time
# against the pane's injected env vars so stable/dev/beta can coexist. Trails
# with `exit 0` so any CLI failure never breaks the agent session.
build_hook_command() {
  local event="$1"
  printf '%s; "${ATRIUM_CLI_PATH:-atrium}" hook emit %s --adapter claude-code --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$event"
}

# Assemble the full hooks object by walking the event table, then append the
# claude-specific context-inject entry whose stdout is consumed as session
# context. Emits JSON shaped like { "SessionStart": [...], ... }.
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

  # Claude-specific: a second SessionStart matcher whose stdout becomes
  # session context. Reads agent-context.md from the active channel's data
  # dir at runtime (ATRIUM_DATA_DIR is injected per-pane).
  local ctx_cmd ctx_entry
  ctx_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && cat "${ATRIUM_DATA_DIR:-$HOME/.atrium}/agent-context.md" 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX")"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"

  printf '%s' "$hooks"
}

ensure_settings_file() {
  local dir
  dir="$(dirname "$SETTINGS_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
}

install_context_file() {
  local source_file
  source_file="$(cd "$(dirname "$0")" && pwd)/../shared/atrium-context.md"
  local dest_dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}"
  [ -f "$source_file" ] || return 0
  mkdir -p "$dest_dir"
  cp "$source_file" "$dest_dir/agent-context.md"
  # Clean up legacy .txt destination from prior installs.
  rm -f "$dest_dir/agent-context.txt"
}

uninstall_mcp_server() {
  if command -v claude &>/dev/null; then
    claude mcp remove -s user atrium 2>/dev/null || true
  fi
}

# Check whether any hook under the listed settings keys matches the atrium
# marker. Args: one or more settings.json key names (e.g. SessionStart).
has_atrium_hooks_in() {
  local keys_json
  keys_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -r \
    --argjson keys "$keys_json" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '[$keys[] as $k | (.hooks[$k] // [])[] | .hooks[]?.command] | any(test($marker))' \
    "$SETTINGS_FILE" 2>/dev/null || echo "false"
}

do_install() {
  ensure_settings_file

  local new_hooks
  new_hooks="$(build_all_hooks)"

  # Deep-merge atrium hooks into existing settings.json. For every key in
  # new_hooks: strip any prior atrium entries, then append fresh ones.
  # Non-atrium hook entries are preserved untouched.
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
    ' "$SETTINGS_FILE")"

  local tmp="${SETTINGS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"

  uninstall_mcp_server
  install_context_file

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    return
  fi

  # Strip atrium entries from every category under .hooks, prune empty arrays,
  # drop .hooks entirely if nothing remains.
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
    ' "$SETTINGS_FILE")"

  local tmp="${SETTINGS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"

  uninstall_mcp_server

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false, "activityHooks": false}'
    return
  fi

  # Session is considered installed only when both SessionStart and
  # SessionEnd are present — matches the prior contract.
  local start end session
  start="$(has_atrium_hooks_in SessionStart)"
  end="$(has_atrium_hooks_in SessionEnd)"
  if [ "$start" = "true" ] && [ "$end" = "true" ]; then
    session="true"
  else
    session="false"
  fi

  local activity
  activity="$(has_atrium_hooks_in PreToolUse PostToolUse Stop Notification UserPromptSubmit PermissionRequest TaskCreated TaskCompleted SubagentStart SubagentStop StopFailure)"

  echo "{\"subcommand\": \"status\", \"installed\": ${session}, \"activityHooks\": ${activity}}"
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

#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Gemini CLI hook installation for atrium.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
SETTINGS_FILE="${HOME}/.gemini/settings.json"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Marker embedded as the first statement of every atrium-owned hook command.
# The regex matches both current and legacy command shapes so install and
# uninstall can still clean up entries written by prior releases.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|atrium/hook-port|/resolve'

# Gemini sanitizes hook environments, stripping some ATRIUM_* vars at hook
# fire time. We probe the filesystem at install time to bake the active
# channel's CLI path as a fallback to ${ATRIUM_CLI_PATH:-...} — runtime env
# still wins when present, baked path kicks in when it doesn't.
if [ -d "${HOME}/.atrium-dev/adapters/gemini" ]; then
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium-dev/bin/atrium-dev"
else
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium/bin/atrium"
fi

# Event table: kebab-case event name, Gemini settings key, matcher.
# Gemini timeouts are in milliseconds (the other adapters use seconds).
EVENTS=$'session-start\tSessionStart\tstartup
session-end\tSessionEnd\t*
user-prompt-submit\tBeforeAgent\t*
pre-tool-use\tBeforeTool\t.*
post-tool-use\tAfterTool\t.*
stop\tAfterAgent\t*
notification\tNotification\t*'

# Build the hook command string for a given event. Trails with `exit 0` so
# any CLI failure never breaks the agent session.
build_hook_command() {
  local event="$1"
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit %s --adapter gemini --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK" "$event"
}

# Assemble the full hooks object by walking the event table.
build_all_hooks() {
  local hooks='{}'
  local event key matcher cmd entry
  while IFS=$'\t' read -r event key matcher; do
    [ -n "${event:-}" ] || continue
    cmd="$(build_hook_command "$event")"
    entry="$(jq -n --arg matcher "$matcher" --arg cmd "$cmd" \
      '[{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
    hooks="$(jq --arg key "$key" --argjson entry "$entry" \
      '.[$key] = (.[$key] // []) + $entry' <<< "$hooks")"
  done <<< "$EVENTS"
  printf '%s' "$hooks"
}

ensure_settings_file() {
  local dir
  dir="$(dirname "$SETTINGS_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
}

install_skill() {
  local skill_dir="${HOME}/.gemini/skills/atrium"
  local source_dir
  source_dir="$(cd "$(dirname "$0")" && pwd)/skills/atrium"
  [ -f "${source_dir}/SKILL.md" ] || return 0
  mkdir -p "$skill_dir"
  cp "${source_dir}/SKILL.md" "${skill_dir}/SKILL.md"
}

uninstall_skill() {
  local skill_dir="${HOME}/.gemini/skills/atrium"
  [ -d "$skill_dir" ] && rm -rf "$skill_dir"
}

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

  # Deep-merge atrium hooks into settings.json via a single reduce over the
  # new_hooks keys. Non-atrium entries in each category are preserved.
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

  install_skill

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    uninstall_skill
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
    ' "$SETTINGS_FILE")"

  local tmp="${SETTINGS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"

  uninstall_skill

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false, "skillInstalled": false}'
    return
  fi

  local session
  session="$(has_atrium_hooks_in SessionStart)"

  local skill="false"
  [ -f "${HOME}/.gemini/skills/atrium/SKILL.md" ] && skill="true"

  echo "{\"subcommand\": \"status\", \"installed\": ${session}, \"skillInstalled\": ${skill}}"
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

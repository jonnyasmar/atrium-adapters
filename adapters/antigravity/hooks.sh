#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Antigravity CLI (agy) hook installation for atrium.
# agy preserves Gemini CLI's JSON hook surface but stores its settings
# under ~/.gemini/antigravity-cli/settings.json instead of ~/.gemini/.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
SETTINGS_FILE="${HOME}/.gemini/antigravity-cli/settings.json"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Marker embedded as the first statement of every atrium-owned hook command.
# The regex matches current and legacy command shapes so install and
# uninstall can still clean up entries written by prior releases.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|skills resolve-manifest|skills resolve-prompt-sigils|atrium/hook-port|/resolve|pane-name-check\.sh'

# Probe the active atrium channel so we can bake an absolute fallback
# CLI path into the hook command. agy inherits Gemini's habit of
# stripping ATRIUM_* env vars at hook fire time, so the baked path is
# load-bearing; ${ATRIUM_CLI_PATH:-...} still wins at runtime when
# present.
if [ -d "${HOME}/.atrium-dev/adapters/antigravity" ] || [ -d "${HOME}/.atrium-dev/adapters/gemini" ]; then
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium-dev/bin/atrium-dev"
else
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium/bin/atrium"
fi

# Event table: kebab-case event name, agy settings key (mirrors Gemini's
# BeforeAgent/AfterAgent/BeforeTool/AfterTool naming), matcher.
# Antigravity timeouts are in milliseconds (inherited from Gemini).
EVENTS=$'session-start\tSessionStart\tstartup
session-end\tSessionEnd\t*
user-prompt-submit\tBeforeAgent\t*
pre-tool-use\tBeforeTool\t.*
post-tool-use\tAfterTool\t.*
stop\tAfterAgent\t*
notification\tNotification\t*'

build_hook_command() {
  local event="$1"
  local adapter_dir
  adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local normalizer=""
  if [ "$event" = "post-tool-use" ]; then
    normalizer="\"${adapter_dir}/normalize-hook-payload.sh\" | "
  fi
  printf '%s; %s"${ATRIUM_CLI_PATH:-%s}" hook emit %s --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$normalizer" "$ATRIUM_CLI_FALLBACK" "$event"
}

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

  # Skills manifest inject on SessionStart. agy parses the hook stdout as
  # the Gemini hookSpecificOutput envelope (per Google's hooks reference);
  # `atrium skills resolve-manifest --adapter antigravity` emits the
  # adapter-normalized shape.
  local ctx_cmd ctx_entry
  ctx_cmd="$(printf '"${ATRIUM_CLI_PATH:-%s}" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter antigravity 2>/dev/null || true' \
    "$ATRIUM_CLI_FALLBACK")"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{matcher: "startup", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"

  # Pane-name nudge on every BeforeAgent fire. Re-uses the gemini envelope
  # shape from pane-name-check.sh — agy speaks the same hookSpecificOutput
  # contract.
  local rename_cmd rename_entry adapter_dir
  adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  rename_cmd="${adapter_dir}/../shared/pane-name-check.sh gemini"
  rename_entry="$(jq -n --arg cmd "$rename_cmd" \
    '[{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson r "$rename_entry" '.BeforeAgent += $r' <<< "$hooks")"

  # +name@scope sigil auto-resolve on BeforeAgent. Emits the gemini-shape
  # additionalContext envelope.
  local sigil_cmd sigil_entry
  sigil_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-%s}" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter antigravity 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK")"
  sigil_entry="$(jq -n --arg cmd "$sigil_cmd" \
    '[{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson s "$sigil_entry" '.BeforeAgent += $s' <<< "$hooks")"

  printf '%s' "$hooks"
}

ensure_settings_file() {
  local dir
  dir="$(dirname "$SETTINGS_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
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

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
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

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false}'
    return
  fi

  local session
  session="$(has_atrium_hooks_in SessionStart)"

  echo "{\"subcommand\": \"status\", \"installed\": ${session}}"
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

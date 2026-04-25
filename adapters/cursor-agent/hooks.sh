#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Cursor Agent hook installation for atrium.
# Cursor reads hooks from ~/.cursor/hooks.json with this shape:
#   { "version": 1, "hooks": { "sessionStart": [ { "type": "command", "command": "...", "timeout": 5 } ] } }
# Event names are camelCase (sessionStart, preToolUse, ...). See
# https://cursor.com/docs/hooks for the full reference.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
HOOKS_FILE="${HOME}/.cursor/hooks.json"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Absolute path to the companion entry script, resolved against this file's
# installed location (e.g. ~/.atrium/adapters/cursor-agent/). Baked into
# every hooks.json entry so Cursor's shellExecutor invokes a plain binary
# rather than an inline shell one-liner (which it silently drops).
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY_SCRIPT="${ADAPTER_DIR}/cursor-hook-entry.sh"

# Regex used by install/uninstall/status to identify hooks we own. Matches
# the entry-script filenames (cursor-hook-entry.sh for the activity flow,
# context-entry.sh for the SessionStart context-inject) plus the pre-
# entry-script marker tokens so old installs still round-trip cleanly.
ATRIUM_HOOK_MARKER_RE='cursor-hook-entry\.sh|context-entry\.sh|atrium-runtime-hook|atrium hook emit|atrium/hook-port|/resolve'

# Event table: the atrium kebab-case event name we emit (passed to the
# entry script as argv[1]), the Cursor camelCase event name we register
# the hook under, and the matcher. Cursor treats matcher as an optional
# regex; "*" and "" are special cases.
#
# Cursor's CLI surfaces no hook event that carries the assistant's response
# text — `afterAgentResponse` is defined in the event enum but is only
# fired by the Cursor IDE app, not the `cursor-agent` CLI (verified in
# the CLI bundle: no executeHookForStep(afterAgentResponse) call site).
# We therefore wire Cursor's native `stop` for the end-of-turn signal
# and accept that atrium's `lastAssistantMessage` stays null for Cursor
# until either Cursor starts firing text-carrying events or we pull the
# text out-of-band from the chat sqlite.
EVENTS=$'session-start\tsessionStart\t*
session-end\tsessionEnd\t*
user-prompt-submit\tbeforeSubmitPrompt\t*
pre-tool-use\tpreToolUse\t.*
post-tool-use\tpostToolUse\t.*
stop\tstop\t*
subagent-start\tsubagentStart\t.*
subagent-stop\tsubagentStop\t*'

# Build the hook command string for a given event. Shape:
#   /abs/path/to/cursor-hook-entry.sh <event>
# All payload normalization + atrium dispatch lives inside the entry script.
# See cursor-hook-entry.sh for the detailed why (Cursor's shellExecutor
# silently drops multi-statement inline pipelines; a plain binary + arg
# invocation is what reliably runs).
build_hook_command() {
  local event="$1"
  printf '%s %s' "$ENTRY_SCRIPT" "$event"
}

# Assemble the full hooks object by walking the event table, then append the
# cursor-specific sessionStart context-inject entry whose stdout is parsed by
# Cursor as JSON with `additional_context` (per cursor.com/docs/hooks).
build_all_hooks() {
  local hooks='{}'
  local event key matcher cmd entry
  while IFS=$'\t' read -r event key matcher; do
    [ -n "${event:-}" ] || continue
    cmd="$(build_hook_command "$event")"
    entry="$(jq -n --arg matcher "$matcher" --arg cmd "$cmd" \
      '[{type: "command", command: $cmd, matcher: $matcher, timeout: 5}]')"
    hooks="$(jq --arg key "$key" --argjson entry "$entry" \
      '.[$key] = (.[$key] // []) + $entry' <<< "$hooks")"
  done <<< "$EVENTS"

  # Second sessionStart entry: shared context-entry.sh emits the JSON shape
  # Cursor consumes as initial system context. Resolved at hook-fire time
  # against the adapter's installed location ($ADAPTER_DIR/../shared/).
  local ctx_cmd ctx_entry
  ctx_cmd="${ADAPTER_DIR}/../shared/context-entry.sh cursor"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{type: "command", command: $cmd, matcher: "*", timeout: 5}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.sessionStart += $ctx' <<< "$hooks")"

  printf '%s' "$hooks"
}

ensure_hooks_file() {
  local dir
  dir="$(dirname "$HOOKS_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir"
  if [ ! -f "$HOOKS_FILE" ]; then
    echo '{"version": 1, "hooks": {}}' > "$HOOKS_FILE"
  fi
}

# Seed the agent-context file from the adapter's bundled source into the
# active channel's data dir, where the sessionStart ctx hook reads it at
# runtime. Silent no-op when the source file is missing. The previous .txt
# destination is also removed so legacy installs don't leave a stale
# companion file behind.
install_context_file() {
  local source_file
  source_file="$(cd "$(dirname "$0")" && pwd)/../shared/atrium-context.md"
  local dest_dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}"
  [ -f "$source_file" ] || return 0
  mkdir -p "$dest_dir"
  cp "$source_file" "$dest_dir/agent-context.md"
  rm -f "$dest_dir/agent-context.txt"
}

# Check whether any atrium-owned hook entries live under the listed event keys.
# Args: one or more event names (e.g. sessionStart).
has_atrium_hooks_in() {
  local keys_json
  keys_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -r \
    --argjson keys "$keys_json" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '[$keys[] as $k | (.hooks[$k] // [])[] | .command // ""] | any(test($marker))' \
    "$HOOKS_FILE" 2>/dev/null || echo "false"
}

do_install() {
  ensure_hooks_file

  local new_hooks
  new_hooks="$(build_all_hooks)"

  # Deep-merge atrium hooks into hooks.json. Strip atrium-owned entries
  # from EVERY key (not just the new ones) so that retiring an event —
  # e.g. we used to wire Cursor's `stop` and now wire `afterAgentResponse`
  # instead — leaves no orphaned atrium entry under the old key. Non-
  # atrium entries in every key are preserved untouched. Then append
  # fresh atrium entries under the new keys. Force version=1: the only
  # schema version Cursor currently accepts.
  local updated
  updated="$(jq \
    --argjson new_hooks "$new_hooks" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '
    .version = 1 |
    .hooks = (.hooks // {}) |
    .hooks |= with_entries(
      .value |= map(select((.command // "") | test($marker) | not))
    ) |
    reduce ($new_hooks | keys_unsorted[]) as $k (.;
      .hooks[$k] = ((.hooks[$k] // []) + $new_hooks[$k])
    ) |
    .hooks |= with_entries(select(.value | length > 0))
    ' "$HOOKS_FILE")"

  local tmp="${HOOKS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_FILE"

  install_context_file

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$HOOKS_FILE" ]; then
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
        .value |= map(select((.command // "") | test($marker) | not))
        | select(.value | length > 0)
      )
      | if (.hooks | length) == 0 then .hooks = {} else . end
    else . end
    ' "$HOOKS_FILE")"

  local tmp="${HOOKS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_FILE"

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  if [ ! -f "$HOOKS_FILE" ]; then
    echo '{"subcommand": "status", "installed": false, "activityHooks": false}'
    return
  fi

  # Session is considered installed only when both sessionStart and
  # sessionEnd carry atrium hooks — matches the contract of other adapters.
  local start end session
  start="$(has_atrium_hooks_in sessionStart)"
  end="$(has_atrium_hooks_in sessionEnd)"
  if [ "$start" = "true" ] && [ "$end" = "true" ]; then
    session="true"
  else
    session="false"
  fi

  local activity
  activity="$(has_atrium_hooks_in preToolUse postToolUse stop beforeSubmitPrompt subagentStart subagentStop)"

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

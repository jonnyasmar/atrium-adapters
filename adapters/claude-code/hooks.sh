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
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|skills resolve-manifest|skills resolve-prompt-sigils|atrium/hook-port|/resolve|pane-name-check\.sh|inject-context\.sh'

# Event table: kebab-case event name, Claude settings key, matcher.
# Each event becomes one hook entry in the corresponding settings.json key.
#
# `TaskCreated` / `TaskCompleted` are intentionally omitted: Claude Code
# fires those on its INTERNAL todo-tracker (`TaskCreate`/`TaskUpdate`
# tool ticks), not on atrium task-card lifecycle. Subscribing here
# generated spurious "moved to review" PTY instructions every time the
# agent ticked off a sub-todo. Atrium's canonical signal for card
# transition is the explicit `atrium task set-in-review` / `set-done`
# CLI commands.
EVENTS=$'session-start\tSessionStart\tstartup|resume
session-end\tSessionEnd\t*
pre-tool-use\tPreToolUse\t.*
post-tool-use\tPostToolUse\t.*
stop\tStop\t.*
notification\tNotification\t.*
user-prompt-submit\tUserPromptSubmit\t.*
permission-request\tPermissionRequest\t.*
subagent-start\tSubagentStart\t.*
subagent-stop\tSubagentStop\t.*
stop-failure\tStopFailure\t.*'

# Build the hook command string for a given event. Resolved at hook-fire time
# against the pane's injected env vars so stable/dev/beta can coexist. Trails
# with `exit 0` so any CLI failure never breaks the agent session.
#
# For `post-tool-use` and `stop` events, the native payload is piped
# through `normalize-hook-payload.sh` first (with the event name as $1)
# so atrium consumes the canonical envelope: `post-tool-use` gets the
# `_atrium` write-attribution envelope (see ../../HOOK_ENVELOPE.md);
# `stop` gets `last_assistant_message` scraped from the transcript so
# the final reply reaches the activity card and timeline. Other events
# stream straight to `atrium hook emit`.
build_hook_command() {
  local event="$1"
  local normalizer=""
  if [ "$event" = "post-tool-use" ] || [ "$event" = "stop" ]; then
    # Use ${ATRIUM_DATA_DIR:-...} so the same hook entry resolves to whichever
    # atrium channel (stable / dev / beta) launched the pane. The PTY layer
    # injects ATRIUM_DATA_DIR at pane spawn (src-tauri/src/pty/manager.rs).
    # Pass the event name as $1 so the normalizer branches per-event
    # (post-tool-use → _atrium write envelope; stop → last_assistant_message).
    normalizer="\"\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/claude-code/normalize-hook-payload.sh\" \"$event\" | "
  fi
  printf '%s; %s"${ATRIUM_CLI_PATH:-atrium}" hook emit %s --adapter claude-code --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$normalizer" "$event"
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
  # session context. Calls `atrium skills resolve-manifest` at hook-fire
  # time so the injected context is the pane-specific v1 manifest emitted
  # by SkillsHandler::manifest() (per-adapter envelope normalization lives
  # there per NFR18). The CLI writes raw bytes shaped for the target
  # harness directly to stdout — no jq, no per-harness wrap here.
  local ctx_cmd ctx_entry
  ctx_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-atrium}" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter claude-code 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX")"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"

  # Pane-name nudge: appended to UserPromptSubmit so the agent gets a
  # per-prompt reminder until the pane is renamed off its default
  # launcher name. Resolved at hook-fire time via ${ATRIUM_DATA_DIR:-...}
  # so stable / dev / beta installs on the same machine don't clobber
  # each other's hook entries.
  local rename_cmd rename_entry
  rename_cmd="\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/shared/pane-name-check.sh claude"
  rename_entry="$(jq -n --arg cmd "$rename_cmd" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson r "$rename_entry" '.UserPromptSubmit += $r' <<< "$hooks")"

  # `+name@scope` sigil auto-resolve: appended to UserPromptSubmit so the
  # CLI scans the prompt for sigils, resolves bodies via the registry,
  # and emits `{"hookSpecificOutput": {"additionalContext": <bodies>},
  # "systemMessage": "↻ loaded: ..."}` for Claude Code to inject as
  # this-turn context. Empty prompts and prompts without sigils emit
  # `{}\n` (no-op envelope). The `|| true` trailer guarantees the hook
  # never blocks prompt submission (NFR8-style fail-open).
  local sigil_cmd sigil_entry
  sigil_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-atrium}" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter claude-code 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX")"
  sigil_entry="$(jq -n --arg cmd "$sigil_cmd" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson s "$sigil_entry" '.UserPromptSubmit += $s' <<< "$hooks")"

  # Epic 77 Story 77.5 — context-injection pipeline delivery: atrium's
  # RunCommandStatusProvider runs in the hook server's context_injection
  # pipeline and the assembled envelope rides the `atriumContext` field on the
  # /api/adapter/* HTTP response. `inject-context.sh <event>` POSTs the native
  # hook payload to that route, reads `atriumContext`, and renders Claude's
  # native envelope per event:
  #   - SessionStart → run-command defined+running list (raw-text/identity, a
  #     SECOND SessionStart context source alongside resolve-manifest).
  #   - PreToolUse   → terse "already running" nudge before a shell-class tool
  #     call (hookSpecificOutput.additionalContext; `{}` no-op otherwise).
  # claude-code is the VERIFIED injection baseline (`hookEnvelopes.preToolUse =
  # hookSpecificOutput`); other adapters declare `preToolUse: none` and wire no
  # PreToolUse injection (the grok-revert lesson: no dead wiring). Resolved via
  # ${ATRIUM_DATA_DIR:-...} so stable / dev / beta installs coexist.
  local inject_base inject_ss inject_pt
  inject_base="\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/claude-code/inject-context.sh"
  inject_ss="$(jq -n --arg cmd "$inject_base session-start" \
    '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson e "$inject_ss" '.SessionStart += $e' <<< "$hooks")"
  inject_pt="$(jq -n --arg cmd "$inject_base pre-tool-use" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson e "$inject_pt" '.PreToolUse += $e' <<< "$hooks")"

  printf '%s' "$hooks"
}

ensure_settings_file() {
  local dir
  dir="$(dirname "$SETTINGS_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
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
  activity="$(has_atrium_hooks_in PreToolUse PostToolUse Stop Notification UserPromptSubmit PermissionRequest SubagentStart SubagentStop StopFailure)"

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

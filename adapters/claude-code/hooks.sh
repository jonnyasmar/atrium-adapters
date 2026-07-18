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
# claude-hook-entry.sh is the post-1.19.2 emit path (Cursor dual-fire guard).
# Legacy inline `hook emit` / inject-context tokens stay so uninstall still
# strips pre-bump installs.
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|claude-hook-entry\.sh|atrium hook emit|skills resolve-manifest|skills resolve-prompt-sigils|atrium/hook-port|/resolve|pane-name-check\.sh|inject-context\.sh'

# Cursor Agent also executes ~/.claude/settings.json hooks. Prefix every
# non-entry atrium command with this so those hijacked invocations no-op
# before they can emit as claude-code, inject Claude context, or nudge
# rename under a Cursor pane. Real Claude Code never sets the var.
CURSOR_GUARD='[ -z "${CURSOR_INVOKED_AS:-}" ] || exit 0'

# Chat sidecar (ATRIUM_CHAT_SDK_HOOKS=1) owns atrium dispatch via SDK hooks.
# Prefix non-entry commands so shell dual-fire is suppressed when user
# settings still load for chat. claude-hook-entry.sh has its own early-exit.
CHAT_SDK_GUARD='[ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || exit 0'

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
stop-failure\tStopFailure\t.*
pre-compact\tPreCompact\t.*
post-compact\tPostCompact\t.*'

# Build the hook command string for a given event. Resolved at hook-fire
# time against the pane's injected env vars so stable/dev/beta can
# coexist. All lifecycle emit goes through claude-hook-entry.sh, which:
#   - refuses Cursor Agent dual-fires (CURSOR_INVOKED_AS + payload shape)
#   - normalizes post-tool-use / stop payloads
#   - trails with exit 0 so any CLI failure never breaks the session
# Path uses ${ATRIUM_DATA_DIR:-...} so the same settings.json entry hits
# whichever atrium channel launched the pane (PTY injects ATRIUM_DATA_DIR).
build_hook_command() {
  local event="$1"
  local entry
  entry="\"\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/claude-code/claude-hook-entry.sh\" $event"
  printf '%s; %s; exit 0' "$ATRIUM_HOOK_MARKER_PREFIX" "$entry"
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

  # Claude-specific: SessionStart context whose stdout becomes session
  # context. Calls `atrium skills resolve-manifest` at hook-fire time so the
  # injected context is the pane-specific v1 manifest emitted by
  # SkillsHandler::manifest() (per-adapter envelope normalization lives there
  # per NFR18). The CLI writes raw bytes shaped for the target harness
  # directly to stdout — no jq, no per-harness wrap here.
  #
  # Split into THREE dedicated SessionStart entries (--section context|agent|
  # skills) instead of one: Claude Code caps hook output at 10K PER hook, so a
  # hook per section gives each section its own 10K budget (max headroom).
  local ctx_section ctx_cmd ctx_entry
  for ctx_section in context agent skills; do
    ctx_cmd="$(printf '%s; %s; %s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-atrium}" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter claude-code --section %s 2>/dev/null || true' \
      "$ATRIUM_HOOK_MARKER_PREFIX" "$CURSOR_GUARD" "$CHAT_SDK_GUARD" "$ctx_section")"
    ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
      '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
    hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"
  done

  # `+name@scope` sigil auto-resolve: appended to UserPromptSubmit so the
  # CLI scans the prompt for sigils, resolves bodies via the registry,
  # and emits `{"hookSpecificOutput": {"additionalContext": <bodies>},
  # "systemMessage": "↻ loaded: ..."}` for Claude Code to inject as
  # this-turn context. Empty prompts and prompts without sigils emit
  # `{}\n` (no-op envelope). The `|| true` trailer guarantees the hook
  # never blocks prompt submission (NFR8-style fail-open).
  local sigil_cmd sigil_entry
  sigil_cmd="$(printf '%s; %s; %s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-atrium}" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter claude-code 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$CURSOR_GUARD" "$CHAT_SDK_GUARD")"
  sigil_entry="$(jq -n --arg cmd "$sigil_cmd" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson s "$sigil_entry" '.UserPromptSubmit += $s' <<< "$hooks")"

  # Epic 77 Story 77.5 / Epic 78 Story 78.3 — context-injection pipeline
  # delivery: atrium's RunCommandStatusProvider (and future post-action /
  # prompt-aware providers) run in the hook server's context_injection pipeline
  # and the assembled envelope rides the `atriumContext` field on the
  # /api/adapter/* HTTP response. `inject-context.sh <event>` POSTs the native
  # hook payload to that route, reads `atriumContext`, and renders Claude's
  # native envelope per event:
  #   - SessionStart      → run-command defined+running list (raw-text/identity,
  #     a SECOND SessionStart context source alongside resolve-manifest).
  #   - UserPromptSubmit  → the pipeline atriumContext, additive to the existing
  #     sigil UserPromptSubmit entry (hookSpecificOutput; `{}` no-op).
  #   - PreToolUse        → terse "already running" nudge before a shell-class
  #     tool call (hookSpecificOutput.additionalContext; `{}` no-op otherwise).
  #   - PostToolUse       → post-action context (the PostToolUse payload carries
  #     the tool RESULT; hookSpecificOutput; `{}` no-op otherwise).
  # claude-code is the VERIFIED injection baseline (every hookEnvelopes kind is
  # hookSpecificOutput); other adapters declare the events they can't consume as
  # `none` and wire no injection there (the grok-revert lesson: no dead wiring).
  # Resolved via ${ATRIUM_DATA_DIR:-...} so stable / dev / beta installs coexist.
  local inject_base inject_ss inject_ups inject_pt inject_post
  inject_base="$CURSOR_GUARD; $CHAT_SDK_GUARD; \${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/claude-code/inject-context.sh"
  inject_ss="$(jq -n --arg cmd "$inject_base session-start" \
    '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson e "$inject_ss" '.SessionStart += $e' <<< "$hooks")"
  inject_ups="$(jq -n --arg cmd "$inject_base user-prompt-submit" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson e "$inject_ups" '.UserPromptSubmit += $e' <<< "$hooks")"
  inject_pt="$(jq -n --arg cmd "$inject_base pre-tool-use" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson e "$inject_pt" '.PreToolUse += $e' <<< "$hooks")"
  inject_post="$(jq -n --arg cmd "$inject_base post-tool-use" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson e "$inject_post" '.PostToolUse += $e' <<< "$hooks")"

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

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
# uninstall can still clean up entries written by prior releases. The
# context-entry.sh filename token is retained as a legacy-only fallback so
# uninstall can still recognize hooks written by pre-59.7 releases that
# routed SessionStart context-injection through shared/context-entry.sh.
# Current installs never emit that path; the token is harmless because no
# new hook command matches it. Remove in a future cleanup release once
# pre-59.7 installs have aged out.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|skills resolve-manifest|skills resolve-prompt-sigils|atrium/hook-port|/resolve|context-entry\.sh|pane-name-check\.sh|inject-context\.sh'

# Gemini sanitizes hook environments, stripping some ATRIUM_* vars at hook
# fire time. We probe the filesystem at install time to bake the active
# channel's CLI + data-dir paths as fallbacks — runtime env still wins when
# present, baked path kicks in when it doesn't. Dev install preferred when
# both channels are present (matches the parallel-channel convention).
if [ -d "${HOME}/.atrium-dev/adapters/gemini" ]; then
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium-dev/bin/atrium-dev"
  ATRIUM_DATA_DIR_FALLBACK="${HOME}/.atrium-dev"
else
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium/bin/atrium"
  ATRIUM_DATA_DIR_FALLBACK="${HOME}/.atrium"
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
#
# For `post-tool-use` events, the native payload is piped through
# `normalize-hook-payload.sh` first so atrium consumes the canonical
# `_atrium` envelope (see ../../HOOK_ENVELOPE.md). Other events stream
# straight to `atrium hook emit`.
build_hook_command() {
  local event="$1"
  local normalizer=""
  if [ "$event" = "post-tool-use" ]; then
    # Resolve via ${ATRIUM_DATA_DIR:-<install-time fallback>} so the same
    # hook works on either channel when env survives, and falls back to
    # the channel we probed at install time when gemini strips it.
    normalizer="$(printf '"${ATRIUM_DATA_DIR:-%s}/adapters/gemini/normalize-hook-payload.sh" | ' "$ATRIUM_DATA_DIR_FALLBACK")"
  fi
  printf '%s; %s"${ATRIUM_CLI_PATH:-%s}" hook emit %s --adapter gemini --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$normalizer" "$ATRIUM_CLI_FALLBACK" "$event"
}

# Assemble the full hooks object by walking the event table, then append the
# gemini-specific context-inject entry whose stdout is parsed by Gemini as JSON
# with hookSpecificOutput.additionalContext (per Google's hooks reference).
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

  # Second SessionStart matcher: calls `atrium skills resolve-manifest`
  # which emits the Gemini hookSpecificOutput envelope (per-adapter
  # normalized in SkillsHandler::manifest() per NFR18). printf bakes
  # $ATRIUM_CLI_FALLBACK into the command at install time — gemini strips
  # ATRIUM_* vars at hook-fire time, so the baked path is load-bearing;
  # ${ATRIUM_CLI_PATH:-...} and ${ATRIUM_PANE_ID:-} stay literal in the
  # printf format so they expand at hook-fire time. No `[ -n "${ATRIUM:-}" ]`
  # guard: gemini's SessionStart only fires inside an atrium-managed pane,
  # and the CLI's NFR8 fast-path (Story 59.6 AC5) writes an exit-0 warning
  # when the runtime is unreachable — never blocks session start.
  local ctx_cmd ctx_entry
  ctx_cmd="$(printf '"${ATRIUM_CLI_PATH:-%s}" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter gemini 2>/dev/null || true' \
    "$ATRIUM_CLI_FALLBACK")"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{matcher: "startup", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"

  # Pane-name nudge: appended to BeforeAgent (gemini's user-prompt-submit
  # equivalent) so the agent gets a per-prompt reminder until the pane is
  # renamed off its default launcher name. Emits the same JSON envelope
  # used by the SessionStart context inject — hookSpecificOutput
  # .additionalContext — pinned to hookEventName "BeforeAgent".
  local rename_cmd rename_entry
  rename_cmd="$(printf '${ATRIUM_DATA_DIR:-%s}/adapters/shared/pane-name-check.sh gemini' "$ATRIUM_DATA_DIR_FALLBACK")"
  rename_entry="$(jq -n --arg cmd "$rename_cmd" \
    '[{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson r "$rename_entry" '.BeforeAgent += $r' <<< "$hooks")"

  # `+name@scope` sigil auto-resolve: appended to BeforeAgent so the CLI
  # scans the prompt for sigils, resolves bodies via the registry, and
  # emits `{"hookSpecificOutput": {"hookEventName": "BeforeAgent",
  # "additionalContext": <bodies>}, "systemMessage": "↻ loaded: ..."}`
  # for Gemini to inject as this-turn context (per Google's hooks
  # reference). Empty prompts emit `{}\n` (no-op envelope). The `|| true`
  # trailer guarantees the hook never blocks prompt submission.
  local sigil_cmd sigil_entry
  sigil_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-%s}" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter gemini 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK")"
  sigil_entry="$(jq -n --arg cmd "$sigil_cmd" \
    '[{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson s "$sigil_entry" '.BeforeAgent += $s' <<< "$hooks")"

  # Epic 77 Story 77.5 — context-injection pipeline delivery: atrium's
  # RunCommandStatusProvider runs in the hook server's context_injection
  # pipeline and the assembled envelope rides the `atriumContext` field on the
  # /api/adapter/gemini/* HTTP response. `inject-context.sh session-start`
  # POSTs the native hook payload to that route, reads `atriumContext`, and
  # renders gemini's native SessionStart envelope (hookSpecificOutput
  # .additionalContext, matching hookEnvelopes.sessionStartManifest) as a
  # SECOND SessionStart context source alongside resolve-manifest.
  #
  # SessionStart ONLY: gemini exposes no additionalContext channel at
  # BeforeTool, so adapter.json declares preToolUse "none" and no PreToolUse
  # injection is wired (the grok-revert lesson: no dead wiring).
  #
  # The data-dir is baked twice: once via ${ATRIUM_DATA_DIR:-<fallback>} to
  # resolve the script path, and again as the script's $2 arg so the script's
  # hook-port lookup survives gemini stripping ATRIUM_DATA_DIR at hook-fire
  # time (runtime env still wins inside the script).
  local inject_cmd inject_entry
  inject_cmd="$(printf '${ATRIUM_DATA_DIR:-%s}/adapters/gemini/inject-context.sh session-start %s' \
    "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_DATA_DIR_FALLBACK")"
  inject_entry="$(jq -n --arg cmd "$inject_cmd" \
    '[{matcher: "startup", hooks: [{type: "command", command: $cmd, timeout: 5000}]}]')"
  hooks="$(jq --argjson e "$inject_entry" '.SessionStart += $e' <<< "$hooks")"

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

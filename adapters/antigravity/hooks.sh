#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Antigravity CLI (agy) hook installation for atrium.
#
# Real agy hook system (per https://www.antigravity.google/docs/hooks):
#   - File: ~/.gemini/config/hooks.json.
#   - Shape: top-level keys are NAMED hooks; each named hook contains
#     event keys (PreToolUse, PostToolUse, PreInvocation, PostInvocation,
#     Stop). Timeout in seconds.
#   - Events agy supports: PreToolUse, PostToolUse, PreInvocation,
#     PostInvocation, Stop. NO SessionStart/SessionEnd/UserPromptSubmit/
#     Notification of its own.
#   - PreToolUse stdout REQUIRES `decision` ("allow"/"deny"/"ask"/
#     "force_ask"). Missing or empty stdout = default deny.
#   - PreInvocation stdin carries `invocationNum` (1-based). atrium emits
#     session-start when it's 1; user-prompt-submit on every invocation.
#   - PostInvocation → atrium `stop` (per-turn done).
#   - Stop → atrium `session-end` (process exit).
#
# Debug:
#   Every hook fire appends a line to /tmp/atrium-agy-hooks.log so we
#   can verify the hook actually executes and what stdin agy delivered.
#   Disable with ATRIUM_HOOK_DEBUG=0.
#
# Subcommands: install, uninstall, status

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
HOOKS_FILE="${HOME}/.gemini/config/hooks.json"
HOOK_NAME="atrium"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"

# agy (like gemini) sanitizes hook environments. We probe the active channel
# at install time and bake fallbacks for both ATRIUM_CLI_PATH and
# ATRIUM_DATA_DIR — runtime env wins when it survives, baked path kicks in
# when it doesn't. Dev install preferred when both channels are present.
if [ -d "${HOME}/.atrium-dev/adapters/antigravity" ]; then
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium-dev/bin/atrium-dev"
  ATRIUM_DATA_DIR_FALLBACK="${HOME}/.atrium-dev"
else
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium/bin/atrium"
  ATRIUM_DATA_DIR_FALLBACK="${HOME}/.atrium"
fi

ensure_hooks_file() {
  mkdir -p "$(dirname "$HOOKS_FILE")"
  [ -f "$HOOKS_FILE" ] || echo '{}' > "$HOOKS_FILE"
}

# Shared debug-log prefix injected into every hook command. Appends one
# line per fire with timestamp, pane id, event name, and exit code of
# the atrium emit (so we can see whether the CLI reached atrium).
LOG='log() { [ "${ATRIUM_HOOK_DEBUG:-1}" = "0" ] && return; printf "[%s] [pane=%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ATRIUM_PANE_ID:-?}" "$*" >> /tmp/atrium-agy-hooks.log 2>/dev/null || true; }'

# PreToolUse: pipe agy stdin through normalize-hook-payload.sh (which
# adds session_id + tool_name + tool_input + _atrium envelope), forward
# to atrium, output {"decision":"allow"} so agy doesn't block the call.
build_pre_tool_use_command() {
  printf '%s; %s; payload=$(cat); log "PreToolUse stdin=$(printf %%s \"$payload\" | head -c 400)"; printf "%%s" "$payload" | "${ATRIUM_DATA_DIR:-%s}/adapters/antigravity/normalize-hook-payload.sh" pre-tool-use | "${ATRIUM_CLI_PATH:-%s}" hook emit pre-tool-use --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>>/tmp/atrium-agy-hooks.log; log "PreToolUse emit rc=$?"; printf "{\\"decision\\":\\"allow\\"}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$LOG" "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_CLI_FALLBACK"
}

build_post_tool_use_command() {
  printf '%s; %s; payload=$(cat); log "PostToolUse stdin=$(printf %%s \"$payload\" | head -c 400)"; printf "%%s" "$payload" | "${ATRIUM_DATA_DIR:-%s}/adapters/antigravity/normalize-hook-payload.sh" post-tool-use | "${ATRIUM_CLI_PATH:-%s}" hook emit post-tool-use --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>>/tmp/atrium-agy-hooks.log; log "PostToolUse emit rc=$?"; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$LOG" "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_CLI_FALLBACK"
}

# PreInvocation: emit both session-start AND user-prompt-submit on every
# fire. We discovered empirically that agy's payload either omits
# `invocationNum` or names it differently — jq extracted 0 every time —
# so the "first-invocation-only" gate never triggered. Atrium handles
# duplicate session-starts idempotently (claude-code's hooks also fire
# session-start on every "startup|resume" SessionStart event, so this is
# the established pattern).
#
# Stdout: piped to inject-context.sh, which (on invocationNum==0) emits an
# agy `injectSteps` envelope carrying the atrium SessionStart manifest,
# pipeline context, and resolved sigils — agy's confirmed same-turn
# context-injection primitive. Continuations / any failure emit `{}`.
build_pre_invocation_command() {
  # PreInvocation fires for EVERY model call. In an agentic tool loop a
  # single user turn produces multiple PreInvocations: invocationNum=0
  # for the user-initiated call, then invocationNum=1, 2, ... for each
  # continuation triggered by tool results. atrium's reducer treats
  # user-prompt-submit as "new turn begins" and clears recentToolCalls,
  # so emitting it on every PreInvocation wipes tool history mid-turn.
  # Gate user-prompt-submit on invocationNum=0; always emit session-start
  # (atrium handles duplicates idempotently — matches claude-code's
  # startup|resume SessionStart pattern).
  printf '%s; %s; payload=$(cat); inv=$(printf "%%s" "$payload" | jq -r ".invocationNum // 0" 2>/dev/null || echo 0); log "PreInvocation inv=$inv stdin=$(printf %%s \"$payload\" | head -c 400)"; printf "%%s" "$payload" | "${ATRIUM_DATA_DIR:-%s}/adapters/antigravity/normalize-hook-payload.sh" session-start | "${ATRIUM_CLI_PATH:-%s}" hook emit session-start --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>>/tmp/atrium-agy-hooks.log; log "session-start emit rc=$?"; if [ "$inv" = "0" ]; then printf "%%s" "$payload" | "${ATRIUM_DATA_DIR:-%s}/adapters/antigravity/normalize-hook-payload.sh" user-prompt-submit | "${ATRIUM_CLI_PATH:-%s}" hook emit user-prompt-submit --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>>/tmp/atrium-agy-hooks.log; log "user-prompt-submit emit rc=$?"; else log "user-prompt-submit suppressed (continuation invocation)"; fi; printf "%%s" "$payload" | ATRIUM_CLI_PATH="${ATRIUM_CLI_PATH:-%s}" ATRIUM_DATA_DIR="${ATRIUM_DATA_DIR:-%s}" "${ATRIUM_DATA_DIR:-%s}/adapters/antigravity/inject-context.sh" 2>>/tmp/atrium-agy-hooks.log; log "inject rc=$?"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$LOG" "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_CLI_FALLBACK" "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_CLI_FALLBACK" "$ATRIUM_CLI_FALLBACK" "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_DATA_DIR_FALLBACK"
}

# PostInvocation fires per model-invocation, not per-turn. With agentic
# tool loops, a single user turn produces multiple PostInvocations (one
# per model call). Wiring it to atrium's `stop` made the activity card
# bounce between active and waiting several times per turn AND cleared
# tool-call details each time. We DO NOT install a PostInvocation hook;
# Stop (gated on fullyIdle) is the per-turn signal.

# Stop fires when an execution terminates. agy's stdin includes
# `fullyIdle: true` + `terminationReason: "NO_TOOL_CALL"` ONLY when the
# turn is genuinely complete (model returned a final answer with no more
# tool calls coming). Without fullyIdle, the same Stop event would fire
# after every tool-execution sub-loop within a turn, causing the same
# bouncing as a naive PostInvocation → stop mapping would.
build_stop_command() {
  printf '%s; %s; payload=$(cat); idle=$(printf "%%s" "$payload" | jq -r ".fullyIdle // false" 2>/dev/null || echo false); log "Stop fullyIdle=$idle stdin=$(printf %%s \"$payload\" | head -c 400)"; if [ "$idle" = "true" ]; then printf "%%s" "$payload" | "${ATRIUM_DATA_DIR:-%s}/adapters/antigravity/normalize-hook-payload.sh" stop | "${ATRIUM_CLI_PATH:-%s}" hook emit stop --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>>/tmp/atrium-agy-hooks.log; log "stop emit rc=$?"; fi; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$LOG" "$ATRIUM_DATA_DIR_FALLBACK" "$ATRIUM_CLI_FALLBACK"
}

build_atrium_hook_block() {
  local pre_tool post_tool pre_invocation stop
  pre_tool="$(build_pre_tool_use_command)"
  post_tool="$(build_post_tool_use_command)"
  pre_invocation="$(build_pre_invocation_command)"
  stop="$(build_stop_command)"

  # NOTE the asymmetric shape: PreToolUse and PostToolUse use the
  # {matcher, hooks: [...]} wrapper because they support tool-name
  # regex matchers. PreInvocation and Stop expect a FLAT handler list
  # directly under the event key — per
  # https://www.antigravity.google/docs/hooks: "For PreInvocation,
  # PostInvocation, and Stop, the structure is simpler (a list of
  # handlers directly under the event key) and the matcher is ignored."
  # Wrapping them in {hooks: [...]} (as we did initially) made agy
  # silently skip those entries — confirmed by hook-fire logs.
  #
  # PostInvocation is intentionally omitted; it fires per-invocation
  # (multiple per turn) and wiring it to atrium's stop caused the
  # activity card to bounce. Stop (gated on fullyIdle) is the per-turn
  # signal.
  jq -n \
    --arg pre_tool "$pre_tool" \
    --arg post_tool "$post_tool" \
    --arg pre_inv "$pre_invocation" \
    --arg stop "$stop" \
    '{
      enabled: true,
      PreToolUse: [{matcher: ".*", hooks: [{type: "command", command: $pre_tool, timeout: 5}]}],
      PostToolUse: [{matcher: ".*", hooks: [{type: "command", command: $post_tool, timeout: 5}]}],
      PreInvocation: [{type: "command", command: $pre_inv, timeout: 5}],
      Stop: [{type: "command", command: $stop, timeout: 5}]
    }'
}

do_install() {
  ensure_hooks_file

  local block
  block="$(build_atrium_hook_block)"

  local updated
  updated="$(jq --argjson b "$block" --arg name "$HOOK_NAME" '. + {($name): $b}' "$HOOKS_FILE")"

  local tmp="${HOOKS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_FILE"

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$HOOKS_FILE" ]; then
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    return
  fi

  local updated
  updated="$(jq --arg name "$HOOK_NAME" 'del(.[$name])' "$HOOKS_FILE")"

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

  local installed
  installed="$(jq -r --arg name "$HOOK_NAME" 'has($name) | tostring' "$HOOKS_FILE" 2>/dev/null || echo "false")"
  echo "{\"subcommand\": \"status\", \"installed\": ${installed}, \"activityHooks\": ${installed}}"
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

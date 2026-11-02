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

ensure_hooks_file() {
  mkdir -p "$(dirname "$HOOKS_FILE")"
  [ -f "$HOOKS_FILE" ] || echo '{}' > "$HOOKS_FILE"
}

# Shared debug-log prefix injected into every hook command. Appends one
# line per fire with timestamp, pane id, event name, and exit code of
# the atrium emit (so we can see whether the CLI reached atrium).
LOG='log() { [ "${ATRIUM_HOOK_DEBUG:-1}" = "0" ] && return; printf "[%s] [pane=%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ATRIUM_PANE_ID:-?}" "$*" >> /tmp/atrium-agy-hooks.log 2>/dev/null || true; }'

# Every hook command is `<abs path to agy-hook-entry.sh> <event>`.
#
# It CANNOT be an inline shell one-liner: the agy CLI (Go) runs hook
# commands through a shell, but the Antigravity ACP server (Python)
# splits on whitespace and execs argv directly. An inline command dies
# there with "External hook 'atrium' failed to execute.", and since
# PreToolUse treats missing stdout as DENY, that blocks every tool call
# in an ACP chat session. A bare path + arg runs correctly under both.
#
# The exec'd command gets no variable expansion, so its path is fixed at
# install time — and every atrium instance (stable, dev, each worktree)
# installs this one global file. It must therefore name no instance: the
# command is a shim beside hooks.json, the same bytes whoever writes it, which
# picks the pane's own instance from $ATRIUM_DATA_DIR at fire time. agy denies
# a tool call when PreToolUse prints nothing, so the shim answers by itself
# outside an atrium pane or when that instance's adapter is gone; a hook
# naming one instance's data dir denied every agy tool call once that dir was
# removed.
HOOK_ENTRY="${HOME}/.gemini/config/atrium-hook.sh"
SHIM='#!/usr/bin/env bash
# Written by atrium'"'"'s antigravity adapter; the same for every atrium instance.
entry="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/antigravity/agy-hook-entry.sh"
if [ -z "${ATRIUM_PANE_ID:-}" ] || [ ! -f "$entry" ]; then
  case "${1:-}" in
    post-tool-use | session-start | stop) printf '"'"'{}\n'"'"' ;;
    *) printf '"'"'{"decision":"allow"}\n'"'"' ;;
  esac
  exit 0
fi
exec bash "$entry" "$@"'

write_shim() {
  if [ -f "$HOOK_ENTRY" ] && [ "$(cat "$HOOK_ENTRY")" = "$SHIM" ]; then
    return
  fi
  mkdir -p "$(dirname "$HOOK_ENTRY")"
  local tmp="${HOOK_ENTRY}.atrium-tmp"
  printf '%s\n' "$SHIM" > "$tmp"
  chmod 0755 "$tmp"
  mv "$tmp" "$HOOK_ENTRY"
}

build_hook_command() {
  printf '%s %s' "$HOOK_ENTRY" "$1"
}

build_atrium_hook_block() {
  local pre_tool post_tool pre_invocation stop
  pre_tool="$(build_hook_command pre-tool-use)"
  post_tool="$(build_hook_command post-tool-use)"
  pre_invocation="$(build_hook_command session-start)"
  stop="$(build_hook_command stop)"

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
  write_shim

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
  rm -f "$HOOK_ENTRY"

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

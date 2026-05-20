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
#     PostInvocation, Stop. There is NO SessionStart/SessionEnd/
#     UserPromptSubmit/Notification.
#   - PreToolUse stdout REQUIRES `decision` ("allow"/"deny"/"ask"/
#     "force_ask"). Missing or empty stdout = default deny — that's the
#     "Tool call denied by jsonhook__atrium_PreToolUse_0_0" message you
#     get if the hook doesn't explicitly allow.
#   - PreToolUse stdin carries `toolCall.name`/`toolCall.args` — atrium's
#     normalizer reads those. PostToolUse only carries `stepIdx` + optional
#     `error`; tool info is NOT replayed on the post side.
#   - PreInvocation stdin carries `invocationNum` (1-based). We emit a
#     session-start to atrium when it's 1 (agy has no real session-start
#     event of its own), and a user-prompt-submit on every invocation.
#   - PostInvocation fires once per turn after the model's response (and
#     any tool calls) complete. Maps cleanly to atrium's `stop`.
#   - Stop fires when the agy execution loop terminates (process exit).
#     Maps to atrium's `session-end`.
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

if [ -d "${HOME}/.atrium-dev/adapters/antigravity" ]; then
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium-dev/bin/atrium-dev"
else
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium/bin/atrium"
fi

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_hooks_file() {
  mkdir -p "$(dirname "$HOOKS_FILE")"
  [ -f "$HOOKS_FILE" ] || echo '{}' > "$HOOKS_FILE"
}

# PreToolUse: pipe agy's stdin payload through normalize-hook-payload.sh
# (which adds the `_atrium` envelope), forward to atrium, then output
# `{"decision":"allow"}` so agy doesn't block the call. Without the
# explicit allow, agy treats an empty/missing decision as deny.
build_pre_tool_use_command() {
  printf '%s; "%s/normalize-hook-payload.sh" | "${ATRIUM_CLI_PATH:-%s}" hook emit pre-tool-use --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>/dev/null; printf "{\\"decision\\":\\"allow\\"}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ADAPTER_DIR" "$ATRIUM_CLI_FALLBACK"
}

# PostToolUse: stdout `{}` is valid (no decision field on this event).
build_post_tool_use_command() {
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit post-tool-use --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK"
}

# PreInvocation: agy gives us `invocationNum`. On the first invocation
# (==1) we emit session-start so atrium's activity card is created;
# every invocation also emits user-prompt-submit. Output `{}` (no
# injectSteps — atrium hooks never inject into agy's trajectory).
build_pre_invocation_command() {
  printf '%s; payload=$(cat); inv=$(printf "%%s" "$payload" | jq -r ".invocationNum // 0" 2>/dev/null || echo 0); if [ "$inv" = "1" ]; then printf "%%s" "$payload" | "${ATRIUM_CLI_PATH:-%s}" hook emit session-start --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>/dev/null; fi; printf "%%s" "$payload" | "${ATRIUM_CLI_PATH:-%s}" hook emit user-prompt-submit --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK" "$ATRIUM_CLI_FALLBACK"
}

# PostInvocation: per-turn "done" signal. Maps to atrium's `stop` so the
# activity card transitions out of "thinking"/"tool-active" when the
# turn completes.
build_post_invocation_command() {
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit stop --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK"
}

# Stop fires only on agy process exit (not per-turn). Maps to atrium's
# `session-end`.
build_stop_command() {
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit session-end --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK"
}

build_atrium_hook_block() {
  local pre_tool post_tool pre_invocation post_invocation stop
  pre_tool="$(build_pre_tool_use_command)"
  post_tool="$(build_post_tool_use_command)"
  pre_invocation="$(build_pre_invocation_command)"
  post_invocation="$(build_post_invocation_command)"
  stop="$(build_stop_command)"

  jq -n \
    --arg pre_tool "$pre_tool" \
    --arg post_tool "$post_tool" \
    --arg pre_inv "$pre_invocation" \
    --arg post_inv "$post_invocation" \
    --arg stop "$stop" \
    '{
      enabled: true,
      PreToolUse: [{matcher: ".*", hooks: [{type: "command", command: $pre_tool, timeout: 5}]}],
      PostToolUse: [{matcher: ".*", hooks: [{type: "command", command: $post_tool, timeout: 5}]}],
      PreInvocation: [{hooks: [{type: "command", command: $pre_inv, timeout: 5}]}],
      PostInvocation: [{hooks: [{type: "command", command: $post_inv, timeout: 5}]}],
      Stop: [{hooks: [{type: "command", command: $stop, timeout: 5}]}]
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

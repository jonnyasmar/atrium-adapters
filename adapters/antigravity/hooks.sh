#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Antigravity CLI (agy) hook installation for atrium.
#
# Real agy hook system (per https://www.antigravity.google/docs/hooks):
#   - File: ~/.gemini/config/hooks.json (NOT ~/.gemini/antigravity-cli/settings.json).
#   - Shape: top-level keys are NAMED hooks; each named hook contains event
#     keys (PreToolUse, PostToolUse, PreInvocation, PostInvocation, Stop).
#       {
#         "atrium": {
#           "PreToolUse":  [{matcher: ".*", hooks: [{type, command, timeout}]}],
#           "PostToolUse": [{matcher: ".*", hooks: [...]}],
#           "PreInvocation": [{hooks: [...]}],   # no matcher
#           "Stop":          [{hooks: [...]}]    # no matcher
#         }
#       }
#   - Events agy supports: PreToolUse, PostToolUse, PreInvocation,
#     PostInvocation, Stop. There is NO SessionStart, NO SessionEnd, NO
#     UserPromptSubmit, NO Notification, NO BeforeTool/AfterTool/
#     BeforeAgent/AfterAgent (those are Gemini CLI; agy has its own surface).
#   - Timeout in SECONDS (Claude/Codex shape), not milliseconds.
#   - PreToolUse stdin payload carries `toolCall.name`/`toolCall.args` —
#     atrium's normalizer reads those. PostToolUse only carries `stepIdx`
#     and optional `error`; tool info is NOT replayed on the post side.
#   - PreToolUse stdout can return `{decision, reason, permissionOverrides}`
#     to gate the call. Atrium hooks return `{}` so the user's permission
#     UI keeps full control.
#
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
HOOKS_FILE="${HOME}/.gemini/config/hooks.json"
HOOK_NAME="atrium"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Marker baked into every atrium-owned hook command so we can recognize ours
# even if the user hand-edits hooks.json or earlier installs left residue.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"

# Probe the active atrium channel so we can bake an absolute fallback CLI
# path. agy may strip the parent shell env at hook fire time on some
# install paths; the baked path is load-bearing. ${ATRIUM_CLI_PATH:-...}
# still wins at runtime when present.
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

# Pre-tool-use: pipe agy's stdin payload through normalize-hook-payload.sh
# (which adds the `_atrium` envelope), then forward to atrium. Always emit
# `{}` on stdout so agy doesn't think we voted on the permission decision.
build_pre_tool_use_command() {
  printf '%s; "%s/normalize-hook-payload.sh" | "${ATRIUM_CLI_PATH:-%s}" hook emit pre-tool-use --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ADAPTER_DIR" "$ATRIUM_CLI_FALLBACK"
}

# Post-tool-use: agy gives us only `stepIdx` + optional `error`. Forward
# the raw payload to atrium so the card transitions; emit `{}` back to agy.
build_post_tool_use_command() {
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit post-tool-use --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK"
}

# Pre-invocation = atrium's user-prompt-submit equivalent (fires before
# every model call, which lines up with "user just submitted a turn").
# Returns `{}` so we don't inject anything into agy's invocation.
build_pre_invocation_command() {
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit user-prompt-submit --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK"
}

# Stop fires when agy's execution loop terminates — the cleanest analogue
# for atrium's `stop` card transition.
build_stop_command() {
  printf '%s; "${ATRIUM_CLI_PATH:-%s}" hook emit stop --adapter antigravity --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; printf "{}\\n"; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$ATRIUM_CLI_FALLBACK"
}

build_atrium_hook_block() {
  local pre_tool post_tool pre_invocation stop
  pre_tool="$(build_pre_tool_use_command)"
  post_tool="$(build_post_tool_use_command)"
  pre_invocation="$(build_pre_invocation_command)"
  stop="$(build_stop_command)"

  jq -n \
    --arg pre_tool "$pre_tool" \
    --arg post_tool "$post_tool" \
    --arg pre_inv "$pre_invocation" \
    --arg stop "$stop" \
    '{
      enabled: true,
      PreToolUse: [{matcher: ".*", hooks: [{type: "command", command: $pre_tool, timeout: 5}]}],
      PostToolUse: [{matcher: ".*", hooks: [{type: "command", command: $post_tool, timeout: 5}]}],
      PreInvocation: [{hooks: [{type: "command", command: $pre_inv, timeout: 5}]}],
      Stop: [{hooks: [{type: "command", command: $stop, timeout: 5}]}]
    }'
}

do_install() {
  ensure_hooks_file

  local block
  block="$(build_atrium_hook_block)"

  # Replace any existing "atrium" hook block; preserve other user-defined hooks.
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

  # If the file is now an empty object, leave it as `{}` for cleanliness.
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

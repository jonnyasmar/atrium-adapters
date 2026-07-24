#!/usr/bin/env bash
set -euo pipefail

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
CONFIG_FILE="${KIMI_HOME}/config.toml"
HOOK_SCRIPT="${ADAPTER_DIR}/kimi-hook.sh"
BEGIN_MARKER="# >>> atrium kimi hooks >>>"
END_MARKER="# <<< atrium kimi hooks <<<"

EVENTS=(
  "SessionStart session-start session-start"
  "SessionEnd session-end session-end"
  "PreToolUse pre-tool-use pre-tool-use"
  "PostToolUse post-tool-use post-tool-use"
  "PostToolUseFailure post-tool-use-failure post-tool-use"
  "UserPromptSubmit user-prompt-submit user-prompt-submit"
  "Stop stop stop"
  "StopFailure stop-failure stop-failure"
  "Interrupt interrupt interrupt"
  "PermissionRequest permission-request permission-request"
  "PermissionResult permission-result permission-response"
  "SubagentStart subagent-start subagent-start"
  "SubagentStop subagent-stop subagent-stop"
  "PreCompact pre-compact pre-compact"
  "PostCompact post-compact post-compact"
  "Notification notification notification"
)

strip_managed_block() {
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    !managed { print }
  ' "$1"
}

do_install() {
  command -v jq >/dev/null 2>&1 || {
    printf '{"error":"jq is required for hook installation"}\n' >&2
    exit 1
  }

  mkdir -p "$KIMI_HOME"
  [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"
  chmod +x "$HOOK_SCRIPT" "$ADAPTER_DIR/normalize-hook-payload.sh" "$ADAPTER_DIR/inject-context.sh"

  local temp command quoted native normalize emit
  temp="$(mktemp "${CONFIG_FILE}.atrium.XXXXXX")"
  strip_managed_block "$CONFIG_FILE" >"$temp"
  printf '\n%s\n' "$BEGIN_MARKER" >>"$temp"

  for mapping in "${EVENTS[@]}"; do
    read -r native normalize emit <<<"$mapping"
    command="ATRIUM_HOOK_MARKER=atrium-runtime-hook \"${HOOK_SCRIPT}\" \"${normalize}\" \"${emit}\""
    quoted="$(printf '%s' "$command" | jq -Rs .)"
    printf '\n[[hooks]]\nevent = "%s"\ncommand = %s\ntimeout = 10\n' "$native" "$quoted" >>"$temp"
  done

  printf '\n%s\n' "$END_MARKER" >>"$temp"
  mv "$temp" "$CONFIG_FILE"
  printf '{"subcommand":"install","installed":true}\n'
}

do_uninstall() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local temp
    temp="$(mktemp "${CONFIG_FILE}.atrium.XXXXXX")"
    strip_managed_block "$CONFIG_FILE" >"$temp"
    mv "$temp" "$CONFIG_FILE"
  fi
  printf '{"subcommand":"uninstall","uninstalled":true}\n'
}

do_status() {
  local installed=false
  if [[ -f "$CONFIG_FILE" ]] \
    && grep -Fq "$BEGIN_MARKER" "$CONFIG_FILE" \
    && grep -Fq "$END_MARKER" "$CONFIG_FILE" \
    && grep -Fq "$HOOK_SCRIPT" "$CONFIG_FILE"; then
    installed=true
  fi
  printf '{"subcommand":"status","installed":%s,"activityHooks":%s}\n' "$installed" "$installed"
}

case "$SUBCOMMAND" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  *)
    printf '{"error":"unknown hooks subcommand"}\n' >&2
    exit 2
    ;;
esac

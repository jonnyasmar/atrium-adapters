#!/usr/bin/env bash
set -euo pipefail

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
CONFIG_FILE="${KIMI_HOME}/config.toml"
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

# Every atrium instance (stable, dev, each worktree) installs into this one
# config, so the block must name no instance: the pane's own instance comes
# from $ATRIUM_DATA_DIR when kimi runs the hook (through a shell), and a hook
# whose instance is gone exits 0, which kimi treats as "no opinion".
hook_block() {
  local mapping native normalize emit
  printf '%s\n' "$BEGIN_MARKER"
  for mapping in "${EVENTS[@]}"; do
    read -r native normalize emit <<<"$mapping"
    printf '\n[[hooks]]\nevent = "%s"\n' "$native"
    printf "command = 'ATRIUM_HOOK_MARKER=atrium-runtime-hook; f=\"\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/kimi/kimi-hook.sh\"; [ -f \"\$f\" ] || exit 0; exec bash \"\$f\" %s %s'\n" "$normalize" "$emit"
    printf 'timeout = 10\n'
  done
  printf '\n%s\n' "$END_MARKER"
}

# The config without atrium's block, stray atrium hook tables or the blank
# lines older installs piled up (see clean-config.awk). Sets CLEANED and
# LEGACY (lines dropped beyond the current block).
clean_config() {
  local report
  report="$(mktemp "${CONFIG_FILE}.atrium.XXXXXX")"
  CLEANED=""
  [[ -f "$CONFIG_FILE" ]] \
    && CLEANED="$(awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" \
      -f "$ADAPTER_DIR/clean-config.awk" "$CONFIG_FILE" 2>"$report")"
  LEGACY="$(cat "$report" 2>/dev/null)"
  rm -f "$report"
  [[ "$LEGACY" =~ ^[0-9]+$ ]] || LEGACY=0
}

# Replaces config.toml with $1 (which ends in a sentinel "x", so command
# substitution keeps its trailing newline) only when its bytes change, keeping
# one backup the first time a cleanup drops more than atrium's own block.
write_config() {
  local content="${1%x}" temp
  if [[ -f "$CONFIG_FILE" ]] && [[ "$(cat "$CONFIG_FILE"; printf x)" == "${content}x" ]]; then
    return
  fi
  if (( LEGACY > 0 )) && [[ -f "$CONFIG_FILE" ]] && [[ ! -e "$CONFIG_FILE.atrium-backup" ]]; then
    cp -p "$CONFIG_FILE" "$CONFIG_FILE.atrium-backup"
  fi
  temp="$(mktemp "${CONFIG_FILE}.atrium.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  printf '%s' "$content" >"$temp"
  # GNU stat first: BSD's -f means --file-system to GNU, which prints a report.
  [[ -f "$CONFIG_FILE" ]] && chmod "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE")" "$temp" 2>/dev/null
  mv "$temp" "$CONFIG_FILE"
  trap - EXIT
}

# Copies of the config an install killed mid-write left behind; they hold its
# credentials.
sweep_stale_temps() {
  find "$KIMI_HOME" -maxdepth 1 -type f -name 'config.toml.atrium.??????' -mmin +10 -exec rm -f {} + 2>/dev/null || true
}

installed_content() {
  if [[ -n "$CLEANED" ]]; then
    printf '%s\n\n%s' "$CLEANED" "$(hook_block)"
  else
    hook_block
  fi
  printf '\n'
}

do_install() {
  mkdir -p "$KIMI_HOME"
  sweep_stale_temps
  clean_config
  write_config "$(installed_content; printf x)"
  printf '{"subcommand":"install","installed":true}\n'
}

do_uninstall() {
  if [[ -f "$CONFIG_FILE" ]]; then
    sweep_stale_temps
    clean_config
    if [[ -n "$CLEANED" ]]; then
      write_config "$CLEANED"$'\n'x
    else
      write_config x
    fi
  fi
  printf '{"subcommand":"uninstall","uninstalled":true}\n'
}

# Installed when an install would change nothing.
do_status() {
  local installed=false expected
  if [[ -f "$CONFIG_FILE" ]]; then
    clean_config
    expected="$(installed_content; printf x)"
    [[ "$(cat "$CONFIG_FILE"; printf x)" == "$expected" ]] && installed=true
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

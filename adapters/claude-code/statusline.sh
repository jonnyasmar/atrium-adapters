#!/usr/bin/env bash
set -euo pipefail

# statusline.sh — Manage Claude Code statusLine installation for atrium.
# Subcommands: install, uninstall, status (default: status).
# Output: JSON to stdout, diagnostics to stderr.
#
# atrium takes over the single `statusLine` slot in ~/.claude/settings.json
# so it can relay Claude Code's `rate_limits` block to the account-usage
# chip (see statusline-relay.sh). Unlike hooks (arrays, marker-stripped),
# `statusLine` is a SINGLE object — so install preserves the user's prior
# command in a sidecar and the relay chains to it, keeping their display.

SUBCOMMAND="${1:-status}"
SETTINGS_FILE="${HOME}/.claude/settings.json"
# Sidecar holding the user's pre-atrium statusLine command, so the relay
# can reproduce their display and uninstall can restore it. Lives next to
# settings.json (shared across atrium instances, which share settings.json).
CHAIN_FILE="${HOME}/.claude/.atrium-statusline-chain"

# Marker embedded as the first statement of the atrium-owned statusLine
# command; install/uninstall/status detect ownership by testing for it.
MARKER="atrium-statusline-relay"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for statusline management"}' >&2
  exit 1
fi

ensure_settings_file() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
  fi
}

# The command string atrium installs into `.statusLine.command`. Resolves
# ATRIUM_DATA_DIR at tick time so stable/dev/beta panes each reach their own
# instance's relay script (the PTY layer injects ATRIUM_DATA_DIR at spawn).
#
# settings.json is GLOBAL but the relay script lives per-instance-data-dir,
# so a pane from an instance that hasn't installed this adapter version yet
# would point at a missing script. The command therefore guards existence:
# run the relay when present, else fall back to the user's saved original
# statusline (the chain file) so their display never breaks — and it never
# spews a "No such file" error into the status bar.
relay_command() {
  # The ${ATRIUM_DATA_DIR:-...} / $HOME refs stay literal on purpose — they
  # must resolve at statusline-tick time in the pane shell, not at install
  # time.
  # shellcheck disable=SC2016
  printf 'ATRIUM_STATUSLINE_MARKER=%s; __s="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/claude-code/statusline-relay.sh"; if [ -x "$__s" ]; then exec "$__s"; fi; __c="$HOME/.claude/.atrium-statusline-chain"; [ -s "$__c" ] && exec sh -c "$(cat "$__c")"' \
    "$MARKER"
}

current_command() {
  jq -r '.statusLine.command // ""' "$SETTINGS_FILE" 2>/dev/null || echo ""
}

is_atrium_owned() {
  case "$(current_command)" in
    *"$MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

do_install() {
  ensure_settings_file

  # Preserve the user's prior command ONCE — only when the current slot is
  # not already atrium-owned. A second instance installing over an
  # atrium-owned slot must not overwrite the saved original with our relay.
  if ! is_atrium_owned; then
    local prior
    prior="$(current_command)"
    if [ -n "$prior" ]; then
      printf '%s' "$prior" > "$CHAIN_FILE"
    else
      rm -f "$CHAIN_FILE"
    fi
  fi

  local cmd updated tmp
  cmd="$(relay_command)"
  updated="$(jq \
    --arg cmd "$cmd" \
    '.statusLine = {"type": "command", "command": $cmd}' \
    "$SETTINGS_FILE")"
  tmp="${SETTINGS_FILE}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    return
  fi

  # Only touch the slot if we own it — never clobber a user statusLine.
  if is_atrium_owned; then
    local updated tmp
    if [ -s "$CHAIN_FILE" ]; then
      local prior
      prior="$(cat "$CHAIN_FILE")"
      updated="$(jq \
        --arg cmd "$prior" \
        '.statusLine = {"type": "command", "command": $cmd}' \
        "$SETTINGS_FILE")"
    else
      updated="$(jq 'del(.statusLine)' "$SETTINGS_FILE")"
    fi
    tmp="${SETTINGS_FILE}.atrium-tmp"
    printf '%s\n' "$updated" > "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
  fi
  rm -f "$CHAIN_FILE"

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local installed="false"
  if [ -f "$SETTINGS_FILE" ] && is_atrium_owned; then
    installed="true"
  fi
  echo "{\"subcommand\": \"status\", \"installed\": ${installed}}"
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

#!/usr/bin/env bash
set -euo pipefail

# statusline.sh — Manage Claude Code statusLine installation for atrium.
# Subcommands: install, uninstall, status (default: status).
# Output: JSON to stdout, diagnostics to stderr.
#
# atrium takes over the single `statusLine` slot in ~/.claude/settings.json
# so it can relay Claude Code's context/quota state to the composer meter (see
# statusline-relay.sh). Unlike hooks (arrays, marker-stripped),
# `statusLine` is a SINGLE object — so install preserves the user's prior
# command in a sidecar and the relay chains to it, keeping their display.

SUBCOMMAND="${1:-status}"
SETTINGS_FILE="${HOME}/.claude/settings.json"
# Shared with hooks.sh: both rewrite settings.json, from every instance.
SETTINGS_LOCK="${HOME}/.claude/.atrium-settings.lock"
# Sidecar holding the user's pre-atrium statusLine command, so the relay
# can reproduce their display and uninstall can restore it. Lives next to
# settings.json (shared across atrium instances, which share settings.json).
CHAIN_FILE="${HOME}/.claude/.atrium-statusline-chain"

# Marker embedded as the first statement of the atrium-owned statusLine
# command; install/uninstall/status detect ownership by testing for it.
MARKER="atrium-statusline-relay"

# <data>/adapters/<name> is a symlink into .managed/<name>/generations/<id>
# and `..` through it resolves physically, so find shared/ from the logical path.
ADAPTER_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$ADAPTER_DIR" in
  */.managed/*/generations/*) SHARED_DIR="${ADAPTER_DIR%/.managed/*}/shared" ;;
  *) SHARED_DIR="${ADAPTER_DIR%/*}/shared" ;;
esac
source "$SHARED_DIR/config-file.sh"

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
  jq -r '.statusLine.command // ""' <<< "$1" 2>/dev/null || echo ""
}

is_atrium_owned() {
  case "$(current_command "$1")" in
    *"$MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

do_install() {
  local cmd
  cmd="$(relay_command)"

  # Steady state, which is nearly every pass: the slot already holds this
  # exact relay. Touch nothing, so no file watcher fires and no concurrent
  # edit to settings.json can be overwritten.
  if [ -f "$SETTINGS_FILE" ] && jq -e --arg cmd "$cmd" \
    '.statusLine == {"type": "command", "command": $cmd}' \
    "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo '{"subcommand": "install", "installed": true}'
    return
  fi

  atrium_config_lock "$SETTINGS_LOCK"
  ensure_settings_file
  local original updated
  original="$(<"$SETTINGS_FILE")"
  # Exits on a settings.json that is not valid JSON, before the chain file
  # below is touched.
  updated="$(jq \
    --arg cmd "$cmd" \
    '.statusLine = {"type": "command", "command": $cmd}' \
    <<< "$original")"

  # Preserve the user's prior command ONCE — only when the current slot is
  # not already atrium-owned. A second instance installing over an
  # atrium-owned slot must not overwrite the saved original with our relay.
  # Saving goes first; dropping a stale chain waits for a successful write.
  local adopting=false prior=""
  if ! is_atrium_owned "$original"; then
    adopting=true
    prior="$(current_command "$original")"
  fi
  if [ -n "$prior" ]; then
    printf '%s' "$prior" > "$CHAIN_FILE"
  fi
  atrium_config_replace "$SETTINGS_FILE" "$original" "$updated"
  if [ "$adopting" = true ] && [ -z "$prior" ]; then
    rm -f "$CHAIN_FILE"
  fi
  atrium_config_unlock

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    return
  fi

  atrium_config_lock "$SETTINGS_LOCK"
  local original
  original="$(<"$SETTINGS_FILE")"
  # Invalid JSON would read as "not ours" and cost the user the saved chain.
  jq empty <<< "$original"

  # Only touch the slot if we own it — never clobber a user statusLine.
  if is_atrium_owned "$original"; then
    local updated
    if [ -s "$CHAIN_FILE" ]; then
      local prior
      prior="$(cat "$CHAIN_FILE")"
      updated="$(jq \
        --arg cmd "$prior" \
        '.statusLine = {"type": "command", "command": $cmd}' \
        <<< "$original")"
    else
      updated="$(jq 'del(.statusLine)' <<< "$original")"
    fi
    atrium_config_replace "$SETTINGS_FILE" "$original" "$updated"
  fi
  rm -f "$CHAIN_FILE"
  atrium_config_unlock

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local installed="false"
  if [ -f "$SETTINGS_FILE" ] && is_atrium_owned "$(<"$SETTINGS_FILE")"; then
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

#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Goose hook installation for atrium.
# Goose auto-discovers plugins at <plugin-root>/atrium-goose/hooks/hooks.json
# (Open Plugins hooks spec: https://open-plugins.com/agent-builders/components/hooks).
#
# <plugin-root> is $HOME/.agents/plugins, unless a global absolute GOOSE_PATH_ROOT
# is set — then Goose looks in $GOOSE_PATH_ROOT/.agents/plugins (verified against
# goose 1.50.0: crates/goose/src/config/paths.rs). Only a GOOSE_PATH_ROOT present
# in this script's environment is honored: hooks are installed when the adapter
# loads, before any launch-profile env is applied, so a per-launch-profile root
# cannot be covered here.
#
# The plugin's hooks.json points every event at the adapter's committed
# goose-hook.sh, which normalizes the payload and relays it to atrium. The wired
# events are those Goose actually dispatches to a plugin: SessionStart,
# SessionEnd, UserPromptSubmit, Stop, and — restored on the normal execution
# path in v1.50.0 — PreToolUse / PostToolUse / PostToolUseFailure. (The three
# tool events simply don't fire on stock 1.49, so wiring them is harmless there.)
#
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="${ADAPTER_DIR}/goose-hook.sh"

case "${GOOSE_PATH_ROOT:-}" in
  /*) PLUGIN_ROOT="${GOOSE_PATH_ROOT}/.agents/plugins" ;;
  *)  PLUGIN_ROOT="${HOME}/.agents/plugins" ;;
esac
PLUGIN_DIR="${PLUGIN_ROOT}/atrium-goose"
HOOKS_JSON="${PLUGIN_DIR}/hooks/hooks.json"

# native Goose event : normalizer event : atrium event to POST
EVENT_MAP='
SessionStart       session-start           session-start
SessionEnd         session-end             session-end
UserPromptSubmit   user-prompt-submit      user-prompt-submit
PreToolUse         pre-tool-use            pre-tool-use
PostToolUse        post-tool-use           post-tool-use
PostToolUseFailure post-tool-use-failure   post-tool-use
Stop               stop                    stop
'

# Goose loads this plugin for every goose process on the machine, and every
# atrium instance (stable, dev, each worktree) installs it. The command names
# no instance: goose runs it through `sh -c`, so the pane's own instance comes
# from $ATRIUM_DATA_DIR at fire time, and a hook whose instance is gone exits
# 0 instead of failing.
hook_command() {
  printf 'f="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/goose/goose-hook.sh"; [ -f "$f" ] || exit 0; exec bash "$f" %s %s' "$1" "$2"
}

do_install() {
  mkdir -p "${PLUGIN_DIR}/hooks"
  chmod +x "$HOOK_SCRIPT" "${ADAPTER_DIR}/normalize-hook-payload.sh"

  local jq_args=() filter='{hooks: {}}'
  while read -r native norm emit; do
    [ -n "$native" ] || continue
    jq_args+=(--arg "n_${native}" "$native" --arg "c_${native}" "$(hook_command "$norm" "$emit")")
    filter="${filter} | .hooks[\$n_${native}] = [ { hooks: [ { type: \"command\", command: \$c_${native} } ] } ]"
  done <<< "$(printf '%s\n' "$EVENT_MAP" | sed '/^[[:space:]]*$/d')"

  jq -n "${jq_args[@]}" "$filter" > "$HOOKS_JSON"
  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  rm -rf "$PLUGIN_DIR"
  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  if [ -f "$HOOKS_JSON" ]; then
    echo '{"subcommand": "status", "installed": true}'
  else
    echo '{"subcommand": "status", "installed": false}'
  fi
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

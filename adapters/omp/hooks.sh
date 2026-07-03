#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Oh My Pi (omp) extension installation for atrium.
#
# Omp (a pi fork) has no shell-callable hook config (TS-only extension API).
# We install a TS extension at ~/.omp/agent/extensions/atrium.ts that subscribes
# to pi's documented lifecycle events (session_start, session_shutdown,
# tool_call, tool_result, input, agent_end) and shells out to
# `atrium hook emit`. Omp loads the file via jiti — no build step.
#
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
EXT_DIR="${HOME}/.omp/agent/extensions"
EXT_FILE="${EXT_DIR}/atrium.ts"

# Marker baked into the extension file so we can recognize ours (vs. a
# user-authored extension that happens to share the name).
ATRIUM_EXT_MARKER='ATRIUM_HOOK_MARKER=atrium-runtime-hook'

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_SOURCE="${ADAPTER_DIR}/extension/atrium.ts"

is_atrium_extension() {
  [ -f "$1" ] && grep -q "$ATRIUM_EXT_MARKER" "$1"
}

do_install() {
  if [ ! -f "$EXT_SOURCE" ]; then
    echo "{\"error\": \"extension template not found at ${EXT_SOURCE}\"}" >&2
    exit 1
  fi

  mkdir -p "$EXT_DIR"

  # If a foreign atrium.ts exists (no marker), bail rather than clobber the
  # user's file.
  if [ -f "$EXT_FILE" ] && ! is_atrium_extension "$EXT_FILE"; then
    echo "{\"error\": \"~/.omp/agent/extensions/atrium.ts exists and was not created by atrium; refusing to overwrite\"}" >&2
    exit 1
  fi

  cp "$EXT_SOURCE" "$EXT_FILE"

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ -f "$EXT_FILE" ] && is_atrium_extension "$EXT_FILE"; then
    rm -f "$EXT_FILE"
  fi
  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local installed="false"
  if is_atrium_extension "$EXT_FILE"; then
    installed="true"
  fi
  echo "{\"subcommand\": \"status\", \"installed\": ${installed}, \"activityHooks\": ${installed}}"
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

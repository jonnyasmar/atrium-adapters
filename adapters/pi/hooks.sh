#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Pi hook management.
#
# Pi's hook surface is TypeScript-only (`pi.on("tool_call", ...)` in an
# extension module under ~/.pi/agent/extensions/) and only one event
# (`tool_call`) is publicly documented. atrium's SDK v2 expects a stable
# command-string hook contract for install/uninstall, so we intentionally
# leave hooks unwired for the pi adapter at this version. The adapter
# still ships launch/resume/sessions, skills, and launcher options —
# parity for everything except the activity-feed hook stream.
#
# When Pi publishes a stable hook config surface (JSON or otherwise), this
# script and the `hooks` map in adapter.json should be filled in to match
# the Claude Code / Codex / Gemini shape.
#
# Subcommands: install, uninstall, status — all no-ops that report success.
# Output: JSON to stdout.

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"

case "$SUBCOMMAND" in
  install)
    echo '{"subcommand": "install", "installed": true}'
    ;;
  uninstall)
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    ;;
  status)
    echo '{"subcommand": "status", "installed": false, "activityHooks": false}'
    ;;
  *)
    echo "{\"error\": \"Unknown subcommand: ${SUBCOMMAND}\"}" >&2
    exit 2
    ;;
esac

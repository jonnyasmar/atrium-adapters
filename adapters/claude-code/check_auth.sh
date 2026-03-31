#!/usr/bin/env bash
set -euo pipefail

# check_auth.sh — Check if Claude Code is authenticated.
# Claude Code stores credentials in the macOS Keychain under
# "Claude Code-credentials". We check via the `security` CLI.
# Output: {"authenticated": true} or {"authenticated": false, "message": "...", "command": "..."}

if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  echo '{"authenticated": true}'
  exit 0
fi

# Detect the binary path for the auth command
CLAUDE_BIN="$(which claude 2>/dev/null || echo "claude")"

echo "{\"authenticated\": false, \"message\": \"Claude Code needs authentication.\", \"command\": \"${CLAUDE_BIN} auth\"}"
exit 0

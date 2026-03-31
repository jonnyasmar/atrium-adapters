#!/usr/bin/env bash
set -euo pipefail

# check_auth.sh — Check if Codex is authenticated.
# Codex stores auth at ~/.codex/auth.json. Check it exists and is >2 bytes.
# Output: {"authenticated": true} or {"authenticated": false, "message": "...", "command": "..."}

AUTH_FILE="${HOME}/.codex/auth.json"

if [ -f "$AUTH_FILE" ]; then
  # Check file size > 2 bytes (empty JSON {} is 2 bytes)
  FILE_SIZE="$(stat -f '%z' "$AUTH_FILE" 2>/dev/null || stat -c '%s' "$AUTH_FILE" 2>/dev/null || echo 0)"
  if [ "$FILE_SIZE" -gt 2 ]; then
    echo '{"authenticated": true}'
    exit 0
  fi
fi

# Detect the binary path for the auth command
CODEX_BIN="$(which codex 2>/dev/null || echo "codex")"

echo "{\"authenticated\": false, \"message\": \"Codex CLI needs authentication.\", \"command\": \"${CODEX_BIN} auth\"}"
exit 0

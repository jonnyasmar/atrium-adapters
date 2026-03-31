#!/usr/bin/env bash
set -euo pipefail

# extract_session_id.sh — Extract the session ID from a running Codex process.
# Codex uses: codex resume <session_id>
# Takes $1 = shell PID
# Output: {"sessionId": "abc-123", "args": null} or {"sessionId": null}

SHELL_PID="${1:?Usage: extract_session_id.sh <shell_pid>}"

# Walk the process tree from the given shell PID looking for codex with "resume <id>"
extract_from_args() {
  local child_pids
  child_pids="$(pgrep -P "$SHELL_PID" 2>/dev/null)" || true

  for pid in $child_pids; do
    local cmd
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || continue

    # Check if this is a codex process
    case "$cmd" in
      codex*|*/codex*) ;;
      *) continue ;;
    esac

    # Look for "resume <id>" — Codex uses "codex resume <session_id>" (not --resume)
    local session_id
    session_id="$(echo "$cmd" | grep -oE 'resume\s+[^ -][^ ]*' | head -1 | awk '{print $2}')" || true

    if [ -n "$session_id" ]; then
      if command -v jq &>/dev/null; then
        jq -n --arg sid "$session_id" '{"sessionId": $sid, "args": null}'
      else
        local escaped
        escaped="$(printf '%s' "$session_id" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        echo "{\"sessionId\": \"${escaped}\", \"args\": null}"
      fi
      exit 0
    fi
  done
}

# Try to extract from process args
extract_from_args

# Not found
echo '{"sessionId": null}'
exit 0

#!/usr/bin/env bash
set -euo pipefail

# extract_session_id.sh — Extract the session ID from a running Claude Code process.
# Takes $1 = shell PID
# Output: {"sessionId": "abc-123", "args": null} or {"sessionId": null}

SHELL_PID="${1:?Usage: extract_session_id.sh <shell_pid>}"

encode_cwd() {
  local cwd="$1"
  # Strip leading slash, replace remaining slashes with dashes, prepend dash
  echo "-${cwd#/}" | tr '/' '-'
}

# Strategy 1: Parse claude process args for --resume <id> or --session-id <id> or -r <id>
extract_from_args() {
  local child_pids
  child_pids="$(pgrep -P "$SHELL_PID" 2>/dev/null)" || true

  for pid in $child_pids; do
    local cmd
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || continue

    # Check if this is a claude process
    case "$cmd" in
      claude*|*/claude*) ;;
      *) continue ;;
    esac

    # Look for --resume <id>, --session-id <id>, or -r <id>
    local session_id
    session_id="$(echo "$cmd" | grep -oE '(--resume|--session-id|-r)\s+[^ ]+' | head -1 | awk '{print $2}')" || true

    if [ -n "$session_id" ]; then
      if command -v jq &>/dev/null; then
        jq -n --arg sid "$session_id" '{"sessionId": $sid, "args": null}'
      else
        # Fallback: escape backslashes and double quotes for JSON safety
        local escaped
        escaped="$(printf '%s' "$session_id" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        echo "{\"sessionId\": \"${escaped}\", \"args\": null}"
      fi
      exit 0
    fi
  done
}

# Strategy 2: Find most recently modified .jsonl in ~/.claude/projects/{encoded-cwd}/
extract_from_filesystem() {
  # Get the CWD of the shell process
  local shell_cwd
  shell_cwd="$(lsof -p "$SHELL_PID" -Fn 2>/dev/null | grep '^n/' | grep 'cwd' | head -1 | sed 's/^n//')" || true

  # Fallback: try /proc or pwdx
  if [ -z "$shell_cwd" ]; then
    shell_cwd="$(pwdx "$SHELL_PID" 2>/dev/null | awk '{print $2}')" || true
  fi

  if [ -z "$shell_cwd" ]; then
    return 1
  fi

  local encoded
  encoded="$(encode_cwd "$shell_cwd")"
  local project_dir="${HOME}/.claude/projects/${encoded}"

  if [ ! -d "$project_dir" ]; then
    return 1
  fi

  # Find the most recently modified .jsonl file
  local latest_file
  latest_file="$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)" || true

  if [ -z "$latest_file" ]; then
    return 1
  fi

  # Extract sessionId from the first "type":"user" line
  local session_id
  if command -v jq &>/dev/null; then
    session_id="$(grep '"type"' "$latest_file" | grep '"user"' | head -1 | jq -r '.sessionId // empty' 2>/dev/null)" || true
  else
    # Fallback: grep/sed extraction
    session_id="$(grep '"type"' "$latest_file" | grep '"user"' | head -1 | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" || true
  fi

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

  # Fallback: use the filename as session ID
  local basename
  basename="$(basename "$latest_file" .jsonl)"
  if [ -n "$basename" ]; then
    if command -v jq &>/dev/null; then
      jq -n --arg sid "$basename" '{"sessionId": $sid, "args": null}'
    else
      local escaped
      escaped="$(printf '%s' "$basename" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      echo "{\"sessionId\": \"${escaped}\", \"args\": null}"
    fi
    exit 0
  fi

  return 1
}

# Try Strategy 1 first
extract_from_args

# Try Strategy 2
extract_from_filesystem || true

# Not found
echo '{"sessionId": null}'
exit 0

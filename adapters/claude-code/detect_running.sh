#!/usr/bin/env bash
set -euo pipefail

# detect_running.sh — Detect if Claude Code is running in a process tree.
# Takes $1 = shell PID
# Output: {"running": true} or {"running": false}

SHELL_PID="${1:?Usage: detect_running.sh <shell_pid>}"

# Check if a process is a claude process by examining its command line.
is_claude_process() {
  local pid="$1"
  local cmd
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  # Check: command is "claude", starts with "claude ", or contains /claude
  case "$cmd" in
    claude|claude\ *|*/claude|*/claude\ *) return 0 ;;
  esac
  return 1
}

# Walk children recursively looking for claude.
walk_children() {
  local parent_pid="$1"
  local depth="$2"

  if [ "$depth" -ge 32 ]; then
    return 1
  fi

  local child_pids
  child_pids="$(pgrep -P "$parent_pid" 2>/dev/null)" || true

  for child_pid in $child_pids; do
    if is_claude_process "$child_pid"; then
      return 0
    fi
    if walk_children "$child_pid" $((depth + 1)); then
      return 0
    fi
  done

  return 1
}

# Walk parents looking for claude.
walk_parents() {
  local current_pid="$1"
  local depth=0

  while [ "$depth" -lt 32 ]; do
    if is_claude_process "$current_pid"; then
      return 0
    fi

    local ppid
    ppid="$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')" || break
    if [ -z "$ppid" ] || [ "$ppid" = "$current_pid" ] || [ "$ppid" = "0" ] || [ "$ppid" = "1" ]; then
      break
    fi
    current_pid="$ppid"
    depth=$((depth + 1))
  done

  return 1
}

# Check children first (most common case)
if walk_children "$SHELL_PID" 0; then
  echo '{"running": true}'
  exit 0
fi

# Check parents
if walk_parents "$SHELL_PID"; then
  echo '{"running": true}'
  exit 0
fi

# Fallback: check for CLAUDECODE=1 env var on the shell process itself
# (may not be readable without elevated privileges)
if ps -o environ= -p "$SHELL_PID" 2>/dev/null | grep -q 'CLAUDECODE=1' 2>/dev/null; then
  echo '{"running": true}'
  exit 0
fi

echo '{"running": false}'
exit 0

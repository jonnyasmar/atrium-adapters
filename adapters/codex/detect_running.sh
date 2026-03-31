#!/usr/bin/env bash
set -euo pipefail

# detect_running.sh — Detect if Codex is running in a process tree.
# Takes $1 = shell PID
# Output: {"running": true} or {"running": false}

SHELL_PID="${1:?Usage: detect_running.sh <shell_pid>}"

# Check if a process is a codex process by examining its command line.
# Matches "codex" (exact) or "codex-*" (Codex spawns child processes with codex- prefix).
is_codex_process() {
  local pid="$1"
  local cmd
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  # Check: command is "codex", starts with "codex ", contains /codex, or matches codex-*
  case "$cmd" in
    codex|codex\ *|*/codex|*/codex\ *) return 0 ;;
    codex-*|*/codex-*) return 0 ;;
  esac
  return 1
}

# Walk children recursively looking for codex.
walk_children() {
  local parent_pid="$1"
  local depth="$2"

  if [ "$depth" -ge 32 ]; then
    return 1
  fi

  local child_pids
  child_pids="$(pgrep -P "$parent_pid" 2>/dev/null)" || true

  for child_pid in $child_pids; do
    if is_codex_process "$child_pid"; then
      return 0
    fi
    if walk_children "$child_pid" $((depth + 1)); then
      return 0
    fi
  done

  return 1
}

# Walk parents looking for codex.
walk_parents() {
  local current_pid="$1"
  local depth=0

  while [ "$depth" -lt 32 ]; do
    if is_codex_process "$current_pid"; then
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

echo '{"running": false}'
exit 0

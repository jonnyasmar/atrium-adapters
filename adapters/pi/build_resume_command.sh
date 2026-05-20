#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume a Pi session.
# Wraps `pi --session <id>` in the same bash chain as launch so the
# session-start / stop / session-end hooks still fire on resume (Pi has
# no shell-callable hook surface; the launch wrapper is the only way to
# get atrium's activity card to update).
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["bash", "-c", "<chain>"]}

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"

PI_ARGS=("--session" "$SESSION_ID")
if command -v jq &>/dev/null; then
  PROVIDER="$(echo "$FLAGS" | jq -r '.provider // ""' 2>/dev/null)" || PROVIDER=""
  [ -n "$PROVIDER" ] && PI_ARGS+=("--provider" "$PROVIDER")

  MODEL="$(echo "$FLAGS" | jq -r '.model // ""' 2>/dev/null)" || MODEL=""
  [ -n "$MODEL" ] && PI_ARGS+=("--model" "$MODEL")

  EXTRA="$(echo "$FLAGS" | jq -r '.extraArgs // ""' 2>/dev/null)" || EXTRA=""
  if [ -n "$EXTRA" ]; then
    for arg in $EXTRA; do
      PI_ARGS+=("$arg")
    done
  fi
fi

escape_single_quoted() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

PI_CMD="pi"
for arg in "${PI_ARGS[@]}"; do
  PI_CMD="${PI_CMD} $(escape_single_quoted "$arg")"
done

CHAIN="( \"\${ATRIUM_CLI_PATH:-atrium}\" hook emit session-start --adapter pi --pane-id \"\${ATRIUM_PANE_ID:-}\" --json </dev/null 2>/dev/null; true ) & ${PI_CMD}; rc=\$?; \"\${ATRIUM_CLI_PATH:-atrium}\" hook emit stop --adapter pi --pane-id \"\${ATRIUM_PANE_ID:-}\" --json </dev/null 2>/dev/null; true; \"\${ATRIUM_CLI_PATH:-atrium}\" hook emit session-end --adapter pi --pane-id \"\${ATRIUM_PANE_ID:-}\" --json </dev/null 2>/dev/null; true; exit \$rc"

ESCAPED_CHAIN="$(printf '%s' "$CHAIN" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
printf '{"command": ["bash", "-c", %s]}\n' "$ESCAPED_CHAIN"
exit 0

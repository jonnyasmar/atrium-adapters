#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Pi coding agent.
#
# Pi has no shell-callable hook surface (extensions are TypeScript only;
# only `pi.on("tool_call", ...)` is documented). To get the activity feed
# to register the pane at all, the launch wraps `pi` in a bash chain that
# fires atrium's `session-start` hook BEFORE the binary boots and
# `session-end`+`stop` AFTER it exits. That gives atrium two anchor
# events per session — enough to create the card and mark it stopped —
# even without per-tool granularity.
#
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["bash", "-c", "<chain>"]}

FLAGS="${1:-"{}"}"

# Assemble the bare pi args first; we'll concat them into the bash chain.
PI_ARGS=()
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

# Build a shell-escaped representation of the pi args. Single-quote each
# arg, and replace any embedded single quotes with the close-quote /
# escaped-quote / open-quote dance.
escape_single_quoted() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

PI_CMD="pi"
for arg in "${PI_ARGS[@]:-}"; do
  PI_CMD="${PI_CMD} $(escape_single_quoted "$arg")"
done

# Compose the wrapper. We deliberately:
#   - Use `${ATRIUM_CLI_PATH:-atrium}` so it works in both dev and stable.
#   - Pass `--pane-id "${ATRIUM_PANE_ID}"` from the runtime env (atrium
#     injects ATRIUM_PANE_ID into every pane's process env).
#   - Discard stderr from atrium so a CLI failure doesn't pollute the
#     pi TUI; trail every emit with `; true` so it never breaks the chain.
#   - Fire session-start as a background subshell so it doesn't delay
#     pi's startup; fire session-end + stop synchronously after pi exits.
CHAIN="( \"\${ATRIUM_CLI_PATH:-atrium}\" hook emit session-start --adapter pi --pane-id \"\${ATRIUM_PANE_ID:-}\" --json </dev/null 2>/dev/null; true ) & ${PI_CMD}; rc=\$?; \"\${ATRIUM_CLI_PATH:-atrium}\" hook emit stop --adapter pi --pane-id \"\${ATRIUM_PANE_ID:-}\" --json </dev/null 2>/dev/null; true; \"\${ATRIUM_CLI_PATH:-atrium}\" hook emit session-end --adapter pi --pane-id \"\${ATRIUM_PANE_ID:-}\" --json </dev/null 2>/dev/null; true; exit \$rc"

# Build JSON output.
ESCAPED_CHAIN="$(printf '%s' "$CHAIN" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
printf '{"command": ["bash", "-c", %s]}\n' "$ESCAPED_CHAIN"
exit 0

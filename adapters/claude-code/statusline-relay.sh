#!/usr/bin/env bash
# atrium-statusline-relay — installed as Claude Code's statusLine command.
#
# Runs on every statusline tick with the session JSON on stdin. It:
#   1. relays the `rate_limits` block to atrium (account-usage chip), but
#      only when the session was spawned by atrium (ATRIUM_PANE_ID set) and
#      only when the block changed since the last tick — the statusline
#      fires several times a second during streaming, so an unthrottled
#      emit would be a firehose;
#   2. reproduces the user's original statusline display (the command
#      preserved by statusline.sh at install) so taking over the slot is
#      invisible to them.
#
# Diagnostics are silenced and it always exits 0 — a statusline failure
# must never disrupt the session or blank the display.
set -uo pipefail

input="$(cat)"
CHAIN_FILE="${HOME}/.claude/.atrium-statusline-chain"

if [ -n "${ATRIUM_PANE_ID:-}" ] && command -v jq >/dev/null 2>&1; then
  rl="$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null || true)"
  if [ -n "$rl" ]; then
    cache="${TMPDIR:-/tmp}/atrium-statusline-${ATRIUM_PANE_ID}.rl"
    prev=""
    [ -f "$cache" ] && prev="$(cat "$cache" 2>/dev/null || true)"
    if [ "$rl" != "$prev" ]; then
      printf '%s' "$rl" > "$cache" 2>/dev/null || true
      # Fire-and-forget: an orphaned bg job in a non-interactive script is
      # not SIGHUP'd on exit, and the socket write is a few ms.
      printf '{"rate_limits":%s}' "$rl" \
        | "${ATRIUM_CLI_PATH:-atrium}" hook emit usage-update \
            --adapter claude-code --pane-id "${ATRIUM_PANE_ID}" >/dev/null 2>&1 &
    fi
  fi
fi

# Chain to the user's original statusline (fed the same stdin), else print
# nothing (empty statusline).
if [ -s "$CHAIN_FILE" ]; then
  chain="$(cat "$CHAIN_FILE")"
  printf '%s' "$input" | eval "$chain" || true
fi
exit 0

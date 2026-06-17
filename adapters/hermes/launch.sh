#!/usr/bin/env bash
# launch.sh — atrium launch wrapper for Hermes.
#
# Hermes creates its session lazily on the first user message, so its first
# hook (on_session_start) doesn't fire until you interact — leaving a freshly
# launched pane looking like a plain terminal with no Hermes activity card.
# To register the pane as a Hermes agent immediately, we emit a session-start
# at spawn, then exec `hermes chat`. The real on_session_start / pre_llm_call
# hooks update the registration with the live session id on the first turn.
#
# On resume the real session id is on argv (--resume <id>), so we register with
# it directly; on a fresh launch we use the pane id as a transient placeholder
# until the first turn supplies the real id.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(cd "$DIR/../.." 2>/dev/null && pwd || echo "$HOME/.atrium")"
case "$(basename "$DATA_DIR")" in
  .atrium-dev*) DEFAULT_CLI="$DATA_DIR/bin/atrium-dev" ;;
  *)            DEFAULT_CLI="$DATA_DIR/bin/atrium" ;;
esac
ATRIUM_CLI="${ATRIUM_CLI_PATH:-}"
if [ -z "$ATRIUM_CLI" ] || [ ! -x "$ATRIUM_CLI" ]; then
  if [ -x "$DEFAULT_CLI" ]; then ATRIUM_CLI="$DEFAULT_CLI"; else ATRIUM_CLI="atrium"; fi
fi

if [ -n "${ATRIUM_PANE_ID:-}" ]; then
  SID="$ATRIUM_PANE_ID"
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--resume" ] || [ "$prev" = "-r" ]; then SID="$arg"; break; fi
    prev="$arg"
  done
  printf '{"session_id":"%s"}' "$SID" \
    | "$ATRIUM_CLI" hook emit session-start --adapter hermes \
        --pane-id "$ATRIUM_PANE_ID" --json >/dev/null 2>&1 || true
fi

exec hermes chat "$@"

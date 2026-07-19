#!/usr/bin/env bash
# hermes-hook.sh — atrium activity bridge for Hermes shell hooks.
#
# Hermes runs shell-hook commands WITHOUT a shell (`shlex.split` +
# `subprocess.run(..., shell=False)`), so the config.yaml entry must be a
# single executable + args — no inline pipelines or env-var expansion. This
# wrapper is that executable. Hermes invokes it as:
#
#     hermes-hook.sh <hermes_event>
#
# with the native hook payload on stdin. We translate the Hermes event to the
# atrium event(s), normalize the payload to atrium's contract, and forward it
# to `atrium hook emit`. Hermes ignores our stdout for these events, so we
# print a no-op `{}` and ALWAYS exit 0 — a CLI failure must never break the
# agent's turn.
set -uo pipefail

HERMES_EVENT="${1:-}"

# Chat-sidecar sessions get activity from the chat runtime's turn bridge —
# engine-side lifecycle emits double-feed the activity card and (with no
# settling stop behind them) wedge it in "working". Hermes ignores stdout
# here, so the plain early exit is safe.
[ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || { printf '{}\n'; exit 0; }

# Only report activity when running inside an atrium pane. Hermes shell hooks
# live in the machine-wide config.yaml, so EVERY hermes process fires them — the
# messaging gateway daemon, cron jobs, `hermes -z` oneshots, manual runs. atrium
# injects ATRIUM_PANE_ID only into its panes, so its absence means this hermes
# was not launched by atrium and has no pane to attribute activity to. Without
# this gate those external processes emit phantom events onto atrium's hermes
# panes. Print the no-op stdout hermes expects and exit cleanly.
if [ -z "${ATRIUM_PANE_ID:-}" ]; then
  printf '{}\n'
  exit 0
fi

# Self-locate. The adapter dir is this script's dir; the atrium data dir is two
# levels up (<data-dir>/adapters/hermes/). Deriving the CLI from our own
# location means one fixed config.yaml entry resolves to whichever atrium
# instance owns this install, with no install-time rewriting. $ATRIUM_CLI_PATH
# from the pane env still wins at fire time when present.
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
NORMALIZE="$DIR/normalize-hook-payload.sh"

payload="$(cat)"

emit() {
  local atrium_event="$1"
  printf '%s' "$payload" \
    | "$NORMALIZE" "$atrium_event" 2>/dev/null \
    | "$ATRIUM_CLI" hook emit "$atrium_event" \
        --adapter hermes --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>&1 || true
}

case "$HERMES_EVENT" in
  on_session_start)
    emit session-start
    ;;
  pre_llm_call)
    # on_session_start does NOT fire on resumed sessions, so re-emit
    # session-start here (atrium dedupes) to register resumed panes, then
    # forward the user prompt.
    emit session-start
    emit user-prompt-submit
    ;;
  pre_tool_call)
    emit pre-tool-use
    ;;
  post_tool_call)
    emit post-tool-use
    ;;
  post_llm_call)
    emit stop
    ;;
esac

printf '{}\n'
exit 0

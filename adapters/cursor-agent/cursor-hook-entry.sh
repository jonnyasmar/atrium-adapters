#!/usr/bin/env bash
# cursor-hook-entry.sh — invoked by Cursor for each configured hook event.
#
# Why a script file instead of an inline shell command in hooks.json:
# Cursor executes hook commands through its internal shellExecutor which
# reliably runs external binaries but was observed to silently drop
# multi-statement inline shell pipelines (leading-assignment prefix, pipe
# to ATRIUM_CLI_PATH, etc.). Staying in one self-contained script keeps
# the invocation trivially binary-shaped.
#
# Args:
#   $1  atrium event name (kebab-case: session-start, pre-tool-use, ...)
#
# Stdin:
#   JSON payload from Cursor (fed via heredoc by the host). May be empty
#   if Cursor skips payload delivery for a given event.
#
# Side-effect:
#   Emits an atrium hook event, aliasing conversation_id → session_id
#   when the latter isn't set so atrium's shared detection path can bind
#   the pane.

set -u

EVENT="${1:?event name required}"
ATRIUM_CLI="${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}"

# Chat-sidecar sessions get activity from the chat runtime's turn bridge —
# engine-side lifecycle emits double-feed the activity card and (with no
# settling stop behind them) wedge it in "working".
[ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || exit 0

# Base transform: alias conversation_id → session_id when the latter is
# absent. Atrium's shared adapter-detection path reads payload.session_id
# uniformly; Cursor emits conversation_id on every hook but session_id
# only on sessionStart.
#
# The filter deliberately avoids jq's `//` alternative-operator — the
# adapter repo previously triggered Cursor's hooks.json loader
# (1357.index.js::parseJSONC) which strips `//...$` without respecting
# string quoting. That bug only mattered when filters were embedded in
# hooks.json directly; here they're in a script file and out of harm's
# way. Convention preserved so the filter reads the same everywhere.
BASE_FILTER='if type=="object" then . + (if .session_id then {} else {session_id: .conversation_id} end) else . end'

# Capture stdin once: the stop case reads the payload (cwd) before the
# dispatch jq below would otherwise consume it.
input="$(cat)"

# Per-event field normalization — translate Cursor-shaped payloads into
# the field names atrium's `parseActivityEvent` reads.
# Resolve the adapter dir up-front: the stop case reaches the
# last-assistant-message helper, the dispatch reaches the normalizer.
# Same `BASH_SOURCE` pattern hooks.sh uses for `pane-name-check.sh`.
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZER="${ADAPTER_DIR}/normalize-hook-payload.sh"

LAST_MSG=""
case "$EVENT" in
  stop)
    # Cursor's `cursor-agent` CLI fires no hook event carrying the assistant
    # response text (`afterAgentResponse` is IDE-only — see hooks.sh). Pull the
    # last assistant message out-of-band from the chat sqlite; best-effort, so
    # absence just leaves lastAssistantMessage null (backfill recovers it later).
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
    [ -n "$cwd" ] || cwd="$PWD"
    LAST_MSG="$(python3 "$ADAPTER_DIR/last-assistant-message.py" --cwd "$cwd" 2>/dev/null || true)"
    if [ -n "$LAST_MSG" ]; then
      EVENT_FILTER='. + {last_assistant_message: $lastmsg}'
    else
      # Legacy path: should a future Cursor `stop` ever carry inline `text`.
      EVENT_FILTER='if type=="object" and has("text") then . + {last_assistant_message: .text} else . end'
    fi
    ;;
  *)
    EVENT_FILTER='.'
    ;;
esac

# For post-tool-use, route through the normalizer so atrium sees the
# canonical `_atrium.filePaths` envelope (see ../../HOOK_ENVELOPE.md).
# Other events skip it — they don't carry write information. `--arg lastmsg`
# is always defined (empty for non-stop) so the stop filter can reference it
# safely; jq ignores it otherwise.
if [ "$EVENT" = "post-tool-use" ] && [ -x "$NORMALIZER" ]; then
  printf '%s' "$input" | jq -c --arg lastmsg "$LAST_MSG" "$BASE_FILTER | $EVENT_FILTER" 2>/dev/null \
    | "$NORMALIZER" 2>/dev/null \
    | "$ATRIUM_CLI" hook emit "$EVENT" --adapter cursor-agent --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null
else
  printf '%s' "$input" | jq -c --arg lastmsg "$LAST_MSG" "$BASE_FILTER | $EVENT_FILTER" 2>/dev/null \
    | "$ATRIUM_CLI" hook emit "$EVENT" --adapter cursor-agent --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null
fi

# Trailing exit 0 so any downstream failure never breaks the agent session.
exit 0

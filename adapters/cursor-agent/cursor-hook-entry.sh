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

# Per-event field normalization — translate Cursor-shaped payloads into
# the field names atrium's `parseActivityEvent` reads.
case "$EVENT" in
  stop)
    # We route Cursor's `afterAgentResponse` to atrium's `stop` (see the
    # EVENTS table in hooks.sh for why). Cursor puts the assistant text
    # in `text`; atrium's reducer reads `last_assistant_message`.
    EVENT_FILTER='if type=="object" and has("text") then . + {last_assistant_message: .text} else . end'
    ;;
  *)
    EVENT_FILTER='.'
    ;;
esac

jq -c "$BASE_FILTER | $EVENT_FILTER" 2>/dev/null \
  | "$ATRIUM_CLI" hook emit "$EVENT" --adapter cursor-agent --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null

# Trailing exit 0 so any downstream failure never breaks the agent session.
exit 0

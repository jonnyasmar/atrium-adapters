#!/usr/bin/env bash
# inject-context.sh — Hermes context injection.
#
# Hermes fires no SessionStart-style context hook, but a `pre_llm_call` shell
# hook that returns {"context": "..."} has its context appended to the turn's
# user message (agent/turn_context.py). That is how atrium delivers its
# injected context to a Hermes agent. Wired as a second pre_llm_call entry
# alongside the activity hook.
#
# Delivers, when running inside an atrium pane:
#   - first turn: the atrium SessionStart manifest (the "you're in atrium"
#     intro + available/always-loaded skills + agent), via `skills
#     resolve-manifest`.
#   - every turn: the pane-rename nudge while the pane still carries its
#     default launcher name, via the shared pane-name-check.sh.
#
# Reads the pre_llm_call payload on stdin; writes {"context": "..."} or the
# no-op {}. Fail-open — any error degrades to {} so a turn never breaks.
set -uo pipefail

# Only inject inside an atrium pane. External hermes processes (gateway, cron,
# oneshots) have neither var and must get nothing.
[ -n "${ATRIUM:-}" ] || { printf '{}\n'; exit 0; }
[ -n "${ATRIUM_PANE_ID:-}" ] || { printf '{}\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }

# Self-locate the atrium CLI / data dir (same scheme as hermes-hook.sh) so one
# fixed config.yaml entry resolves to whichever atrium instance owns the pane.
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
NUDGE_SCRIPT="$DATA_DIR/adapters/shared/pane-name-check.sh"

payload="$(cat 2>/dev/null || true)"
is_first="$(printf '%s' "$payload" | jq -r '.extra.is_first_turn // false' 2>/dev/null || echo false)"

parts=""
append() { [ -n "$1" ] || return 0; if [ -n "$parts" ]; then parts="${parts}"$'\n\n'"$1"; else parts="$1"; fi; }

# First turn: the atrium manifest (intro + skills + agent), byte-exact. Only
# inject a real manifest — never the CLI's stdout degradation message (e.g.
# "atrium skills unavailable") when the app is momentarily unreachable.
if [ "$is_first" = "true" ]; then
  manifest="$("$ATRIUM_CLI" skills resolve-manifest --pane-id "$ATRIUM_PANE_ID" --adapter hermes 2>/dev/null || true)"
  case "$manifest" in
    *"ATRIUM CONTEXT MANIFEST"*) append "$manifest" ;;
  esac
fi

# Every turn: pane-rename nudge (the shared script emits bare text under `raw`,
# or nothing once the pane has a non-default name).
if [ -x "$NUDGE_SCRIPT" ]; then
  append "$(ATRIUM_CLI_PATH="$ATRIUM_CLI" bash "$NUDGE_SCRIPT" raw 2>/dev/null || true)"
fi

if [ -n "$parts" ]; then
  jq -n --arg c "$parts" '{context: $c}'
else
  printf '{}\n'
fi
exit 0

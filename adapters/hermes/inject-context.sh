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
#     intro + available/always-loaded skills + agent) via `skills
#     resolve-manifest`, plus the SessionStart context_injection pipeline
#     `atriumContext` (Epic 77 — RunCommandStatusProvider et al.).
#   - every turn: the UserPromptSubmit pipeline `atriumContext` (Epic 78 —
#     prompt-aware providers, INCLUDING the pane-rename nudge — see below) and
#     resolved `+name` sigil bodies for this turn's prompt.
#
# The pane-rename nudge is delivered by the SERVER pipeline (PaneRenameNudge
# provider, capable at UserPromptSubmit), so it rides inside the user-prompt-
# submit `atriumContext` — the adapter no longer emits its own nudge (that would
# double it).
#
# hermes has no tool-event injection point (its shell hooks fire on tool
# call/return but carry no inject-back channel), so only SessionStart +
# UserPromptSubmit are wired — mirroring the adapter.json hookEnvelopes.
#
# The pipeline context rides the `atriumContext` field of the hook server's
# /api/adapter/hermes/<event> JSON response (raw text — the adapter re-emits it
# via hermes's native {context} field, no Claude envelope). The pane id rides
# the X-Atrium-Pane-Id header.
#
# Reads the pre_llm_call payload on stdin; writes {"context": "..."} or the
# no-op {}. Fail-open — any error (curl timeout, missing hook-port, malformed
# JSON, unreachable CLI) degrades to whatever context we already have (or {}),
# so a turn never breaks.
set -uo pipefail

# Chat sidecar owns injection; Hermes expects a JSON object on stdout.
if [ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]; then
  printf '{}\n'
  exit 0
fi

# Only inject inside an atrium pane. External hermes processes (gateway, cron,
# oneshots) have neither var and must get nothing.
[ -n "${ATRIUM:-}" ] || { printf '{}\n'; exit 0; }
[ -n "${ATRIUM_PANE_ID:-}" ] || { printf '{}\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }

# Self-locate the atrium CLI / data dir (same scheme as hermes-hook.sh) so one
# fixed config.yaml entry resolves to whichever atrium instance owns the pane.
# The adapter dir is this script's dir; the data dir is two levels up
# (<data-dir>/adapters/hermes/) — that is also where the running app writes
# `hook-port`, so it stays correct under worktree isolation.
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

# Drain the native pre_llm_call payload. Hermes serializes it as
# { hook_event_name, tool_name, tool_input, session_id, cwd, extra{...} }
# with extra.is_first_turn and extra.user_message (agent/shell_hooks.py).
# Any subsequent jq that BUILDS json uses `jq -n` (stdin already consumed).
payload="$(cat 2>/dev/null || true)"
is_first="$(printf '%s' "$payload" | jq -r '.extra.is_first_turn // false' 2>/dev/null || echo false)"
prompt="$(printf '%s' "$payload" | jq -r '.extra.user_message // empty' 2>/dev/null || true)"

parts=""
append() { [ -n "$1" ] || return 0; if [ -n "$parts" ]; then parts="${parts}"$'\n\n'"$1"; else parts="$1"; fi; }

# POST the native pre_llm_call payload to the hook server's context_injection
# route for $1 (session-start | user-prompt-submit) and echo `.atriumContext`
# (raw text). Fail-open: any missing dep / port / failure / empty body → "".
# ONE localhost round-trip, short timeouts — well under hermes's hook budget.
fetch_pipeline_context() {
  local event="$1" port_file port response
  command -v curl >/dev/null 2>&1 || return 0
  port_file="${DATA_DIR}/hook-port"
  [ -f "$port_file" ] || return 0
  port="$(cat "$port_file" 2>/dev/null || true)"
  [ -n "$port" ] || return 0
  response="$(curl -fsS \
    --max-time 2 \
    --connect-timeout 1 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Atrium-Pane-Id: ${ATRIUM_PANE_ID}" \
    --data-binary "$payload" \
    "http://127.0.0.1:${port}/api/adapter/hermes/${event}" 2>/dev/null || true)"
  [ -n "$response" ] || return 0
  printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true
}

# First turn: the atrium manifest (intro + skills + agent), byte-exact. Only
# inject a real manifest — never the CLI's stdout degradation message (e.g.
# "atrium skills unavailable") when the app is momentarily unreachable.
if [ "$is_first" = "true" ]; then
  manifest="$("$ATRIUM_CLI" skills resolve-manifest --pane-id "$ATRIUM_PANE_ID" --adapter hermes 2>/dev/null || true)"
  case "$manifest" in
    *"ATRIUM CONTEXT MANIFEST"*) append "$manifest" ;;
  esac
  # SessionStart pipeline context (run-command status, etc.).
  append "$(fetch_pipeline_context session-start)"
fi

# Every turn: UserPromptSubmit pipeline context (prompt-aware providers).
append "$(fetch_pipeline_context user-prompt-submit)"

# Every turn: resolve `+name@scope` sigil bodies for this turn's prompt. Unlike
# antigravity (whose PreInvocation payload lacks the prompt), hermes's
# pre_llm_call payload carries extra.user_message, so we resolve directly.
if [ -n "$prompt" ]; then
  sigils="$(jq -cn --arg p "$prompt" '{prompt: $p}' 2>/dev/null \
    | "$ATRIUM_CLI" skills resolve-prompt-sigils --pane-id "$ATRIUM_PANE_ID" --adapter hermes 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  append "$sigils"
fi

if [ -n "$parts" ]; then
  jq -n --arg c "$parts" '{context: $c}'
else
  printf '{}\n'
fi
exit 0

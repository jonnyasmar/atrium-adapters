#!/usr/bin/env bash
# inject-context.sh — Antigravity (agy) PreInvocation context injector.
#
# Reads the PreInvocation payload on stdin and writes an agy `injectSteps`
# envelope to stdout carrying atrium's session context for this turn:
#   1. the SessionStart manifest (atrium-context.md + skills — tells the
#      agent it's running inside atrium and how to drive the CLI),
#   2. resolved `+name` sigil bodies for this turn's prompt,
#   3. the pane-rename nudge while the pane name is still generic.
#
# Confirmed agy envelope (verified 2026-06-04 via an isolated `agy --print`
# probe — the agent obeyed an injected directive):
#   {"injectSteps":[{"systemMessage":{"systemMessage":"<text>"}}, ...]}
# Each HookInjectedStep carries a HookSystemMessage whose `systemMessage`
# field is the text. agy's injected steps are per-invocation (ephemeral, not
# persisted to the conversation), so we re-inject every turn — which also
# means the context survives agy's context compaction.
#
# Gating: only the first invocation of a user turn (invocationNum==0) injects;
# continuation invocations (tool-loop steps) emit "{}" so the manifest isn't
# re-injected mid-turn. Fail-open everywhere: any error emits "{}" so a slow
# or unreachable atrium CLI never breaks agy's turn.
#
# ATRIUM_CLI_PATH / ATRIUM_DATA_DIR are passed in by the PreInvocation hook
# command (baked channel fallback at install time) because agy sanitizes the
# hook environment; ATRIUM_PANE_ID survives and is required.

set -u

payload="$(cat 2>/dev/null || true)"

emit_noop() {
  printf '{}\n'
  exit 0
}

[ -n "${ATRIUM_PANE_ID:-}" ] || emit_noop
command -v jq >/dev/null 2>&1 || emit_noop

inv="$(printf '%s' "$payload" | jq -r '.invocationNum // 0' 2>/dev/null || echo 0)"
[ "$inv" = "0" ] || emit_noop

CLI="${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}"
DATA="${ATRIUM_DATA_DIR:-$HOME/.atrium}"

steps_json='[]'
add_step() {
  local text="$1"
  # Skip empty / whitespace-only parts.
  [ -n "${text//[[:space:]]/}" ] || return 0
  # `-n` (null input) is required: stdin was already drained by the
  # `payload="$(cat)"` above, so without it jq would block/EOF and the
  # `|| keep` fallback would make every add_step a silent no-op.
  steps_json="$(jq -cn --arg t "$text" --argjson arr "$steps_json" \
    '$arr + [{systemMessage: {systemMessage: $t}}]' 2>/dev/null || printf '%s' "$steps_json")"
}

# 1. Manifest (atrium-context.md + skills) — identity envelope → raw text.
manifest="$("$CLI" skills resolve-manifest --pane-id "$ATRIUM_PANE_ID" --adapter antigravity 2>/dev/null || true)"
add_step "$manifest"

# 2. Sigils — resolve `+name` bodies for this turn's prompt. agy's
#    PreInvocation payload doesn't carry the prompt text, so read the latest
#    history.jsonl entry (same source normalize-hook-payload.sh uses).
HISTORY="${HOME}/.gemini/antigravity-cli/history.jsonl"
prompt=""
if [ -f "$HISTORY" ]; then
  prompt="$(tail -n 1 "$HISTORY" 2>/dev/null | jq -r '.display // empty' 2>/dev/null || true)"
fi
sigils="$(jq -cn --arg p "$prompt" '{prompt: $p}' 2>/dev/null \
  | "$CLI" skills resolve-prompt-sigils --pane-id "$ATRIUM_PANE_ID" --adapter antigravity 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
add_step "$sigils"

# 3. Rename nudge — canonical text + generic-name check live in
#    pane-name-check.sh's `raw` shape (single source); empty when the pane
#    has already been renamed.
nudge="$("$DATA/adapters/shared/pane-name-check.sh" raw 2>/dev/null || true)"
add_step "$nudge"

if [ "$steps_json" = "[]" ]; then
  emit_noop
fi

jq -cn --argjson steps "$steps_json" '{injectSteps: $steps}' 2>/dev/null || emit_noop
exit 0

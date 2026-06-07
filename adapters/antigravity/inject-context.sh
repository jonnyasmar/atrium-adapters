#!/usr/bin/env bash
# inject-context.sh — Antigravity (agy) PreInvocation context injector.
#
# Reads the PreInvocation payload on stdin and writes an agy `injectSteps`
# envelope to stdout carrying atrium's session context for this turn:
#   1. the SessionStart manifest (atrium-context.md + skills — tells the
#      agent it's running inside atrium and how to drive the CLI),
#   2. the SessionStart run-command pipeline `atriumContext` from the hook
#      server's context_injection pipeline (Epic 77 — RunCommandStatusProvider),
#   2b. the UserPromptSubmit pipeline `atriumContext` (Epic 78 Story 78.3 —
#      agy's PreInvocation hook IS its UserPromptSubmit-equivalent),
#   3. resolved `+name` sigil bodies for this turn's prompt,
#   4. the pane-rename nudge while the pane name is still generic.
#
# agy is injection-CAPABLE at SessionStart + UserPromptSubmit (both via this one
# PreInvocation hook, fired per user turn): it has no native SessionStart, so
# atrium maps SessionStart→PreInvocation gated on invocationNum==0. agy's
# PreToolUse (PreToolHookResult) and its post-tool path have no inject_steps
# field, so PreToolUse and PostToolUse are NOT injection points (postToolUse:
# none) — the run-command + prompt context ride this PreInvocation step.
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

# Pipeline context (Epic 77/78): POST the native PreInvocation payload to the
# hook server's route for the given event and read `.atriumContext`. The
# context_injection pipeline (RunCommandStatusProvider et al.) runs server-side
# and its provider output is event-specific; its assembled envelope rides the
# `atriumContext` field. $1 is the kebab-case event (session-start |
# user-prompt-submit). Fail-open: any missing dep / port / failure / empty body
# returns "" and the caller skips it.
fetch_pipeline_context() {
  local event="$1"
  command -v curl >/dev/null 2>&1 || return 0
  local port_file="${DATA}/hook-port"
  [ -f "$port_file" ] || return 0
  local port
  port="$(cat "$port_file" 2>/dev/null || true)"
  [ -n "$port" ] || return 0
  local response
  response="$(curl -fsS \
    --max-time 2 \
    --connect-timeout 1 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Atrium-Pane-Id: ${ATRIUM_PANE_ID}" \
    --data-binary "$payload" \
    "http://127.0.0.1:${port}/api/adapter/antigravity/${event}" 2>/dev/null || true)"
  [ -n "$response" ] || return 0
  printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true
}

# 1. Manifest (atrium-context.md + skills) — identity envelope → raw text.
manifest="$("$CLI" skills resolve-manifest --pane-id "$ATRIUM_PANE_ID" --adapter antigravity 2>/dev/null || true)"
add_step "$manifest"

# 2. SessionStart run-command pipeline context — assembled by the hook server's
#    context_injection pipeline, delivered as its own injectSteps systemMessage.
pipeline_ctx="$(fetch_pipeline_context session-start)"
add_step "$pipeline_ctx"

# 2b. UserPromptSubmit pipeline context (Epic 78 Story 78.3). antigravity is
#     injection-capable at UserPromptSubmit via this same PreInvocation hook
#     (it has no PostToolUse inject point). inv==0 fires on each new user turn,
#     so the UserPromptSubmit pipeline channel rides here as a distinct step —
#     78.4's prompt-aware provider serves different content at user-prompt-submit
#     than at session-start.
ups_ctx="$(fetch_pipeline_context user-prompt-submit)"
add_step "$ups_ctx"

# 3. Sigils — resolve `+name` bodies for this turn's prompt. agy's
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

# 4. Rename nudge — canonical text + generic-name check live in
#    pane-name-check.sh's `raw` shape (single source); empty when the pane
#    has already been renamed.
nudge="$("$DATA/adapters/shared/pane-name-check.sh" raw 2>/dev/null || true)"
add_step "$nudge"

if [ "$steps_json" = "[]" ]; then
  emit_noop
fi

jq -cn --argjson steps "$steps_json" '{injectSteps: $steps}' 2>/dev/null || emit_noop
exit 0

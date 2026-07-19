#!/usr/bin/env bash
# pane-name-check.sh — raw-shape pane rename nudge for adapters that cannot
# consume atrium's UserPromptSubmit context-injection pipeline.
#
# The context-injection pipeline provider is the canonical nudge path for
# pipeline-capable adapters. This script remains for raw/native hook shapes
# that cannot consume that pipeline, and for cleaning up legacy hook wiring.
#
# Args:
#   $1  shape — one of: claude | codex | grok | cursor | raw
#       (controls stdout envelope shape; `raw` emits the bare nudge text for
#       plugin/extension adapters that wrap it themselves. Mirrors the
#       per-adapter `hookEnvelopes` declaration in adapter.json that
#       SkillsHandler uses for sigil resolution per NFR18). Do not wire this
#       alongside a consumable UserPromptSubmit pipeline route: the provider
#       already contributes the same nudge there. Cursor Agent's UPS kind is
#       `none`, and Hermes declares no UPS envelope, so their raw/native paths
#       remain valid consumers.
#
# Behavior:
#   - Always emits valid JSON to stdout. Codex strictly parses every
#     UserPromptSubmit hook fire as JSON; an empty/raw exit triggers
#     "hook returned invalid user prompt submit JSON output". The script
#     defaults to `{}` (no-op envelope) when the nudge shouldn't fire,
#     and emits the per-shape additionalContext envelope when it should.
#   - Silent (no nudge) when outside atrium, when ATRIUM_PANE_ID is unset,
#     when the CLI is not reachable, when the pane name is already
#     non-generic, or when ATRIUM_PANE_RENAME_NUDGE=0.
#
# Why no flag-file guard:
#   The reminder must fire on every prompt while the pane is still generic.
#   A "we already nudged" flag would let the agent skip the rename once
#   and silence future reminders — which is exactly the failure mode we're
#   trying to fix. Once the pane is renamed, the generic-name check fails
#   and the script emits an empty `{}`, so the steady-state cost is one
#   CLI lookup per prompt and zero context injected.
#
# Escape hatch:
#   ATRIUM_PANE_RENAME_NUDGE=0 disables the nudge entirely (still emits
#   `{}` to keep Codex happy).

set -u

# Chat sidecar owns atrium UserPromptSubmit work via SDK hooks — no-op.
if [ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]; then
  case "${1:-}" in
    raw) printf '\n' ;;
    *) printf '%s\n' '{}' ;;
  esac
  exit 0
fi

SHAPE="${1:?shape arg required (claude|codex|grok|cursor|raw)}"

# Default no-op output. Shell-hook shapes need valid JSON (`{}`); the `raw`
# shape (consumed by plugin/extension adapters + antigravity's injectSteps
# builder, which wrap the text themselves) wants an empty string so the
# caller can detect "no nudge" by emptiness.
if [ "$SHAPE" = "raw" ]; then
  EMIT=""
else
  EMIT='{}'
fi

# The trap guarantees the closing emit + exit so every code path stays
# output-safe (valid JSON for hook shapes, empty/text for raw).
finish() {
  printf '%s\n' "$EMIT"
  exit 0
}
trap finish EXIT

# Build the per-shape JSON envelope around a context string. Sets EMIT.
build_envelope() {
  local context="$1"
  case "$SHAPE" in
    claude)
      # Claude UserPromptSubmit: hookEventName is PascalCase. Claude also
      # tolerates raw stdout, but the JSON envelope unifies the four shapes
      # and avoids accidental drift if the contract tightens later.
      EMIT="$(jq -n --arg c "$context" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' \
        2>/dev/null || printf '%s' '{}')"
      ;;
    codex)
      # Codex UserPromptSubmitHookSpecificOutputWire is camelCase with
      # deny_unknown_fields, and hookEventName is the HookEventNameWire
      # enum whose accepted values are PascalCase ("UserPromptSubmit"),
      # per codex-rs/hooks/schema/generated/user-prompt-submit.command.output.schema.json.
      # An earlier revision of this script emitted snake_case here based
      # on a misread of the schema dump in the codex binary; that produced
      # an envelope that parsed as JSON but failed serde validation,
      # triggering "hook returned invalid user prompt submit JSON output"
      # for every prompt.
      EMIT="$(jq -n --arg c "$context" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' \
        2>/dev/null || printf '%s' '{}')"
      ;;
    grok)
      # Grok is Claude-settings-compatible: its UserPromptSubmit hook
      # consumes hookSpecificOutput.additionalContext identically to Claude
      # (adapter.json declares hookEnvelopes.userPromptSubmit kind
      # "hookSpecificOutput", hookEventName "UserPromptSubmit"). Same
      # envelope as the claude/codex arm.
      EMIT="$(jq -n --arg c "$context" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' \
        2>/dev/null || printf '%s' '{}')"
      ;;
    cursor)
      # Cursor beforeSubmitPrompt: additional_context (snake_case top-
      # level field). Same envelope shape as the SessionStart manifest
      # inject emitted by SkillsHandler.
      EMIT="$(jq -n --arg c "$context" \
        '{additional_context: $c}' \
        2>/dev/null || printf '%s' '{}')"
      ;;
    raw)
      # Bare reminder text, no JSON envelope. Plugin/extension adapters
      # (pi, opencode) and antigravity's injectSteps builder call this to
      # get the canonical nudge text + generic-name check from one place,
      # then wrap it in their own injection mechanism. Non-generic panes
      # never reach build_envelope, so the EXIT default ("") signals "no
      # nudge".
      EMIT="$context"
      ;;
    *)
      echo "pane-name-check.sh: unknown shape '$SHAPE'" >&2
      EMIT='{}'
      ;;
  esac
}

# Pre-conditions for the nudge. Each early return leaves EMIT='{}' so the
# trap emits a no-op envelope.
[ -n "${ATRIUM:-}" ] || exit 0
[ -n "${ATRIUM_PANE_ID:-}" ] || exit 0
[ "${ATRIUM_PANE_RENAME_NUDGE:-1}" != "0" ] || exit 0

ATRIUM_CLI="${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}"
[ -x "$ATRIUM_CLI" ] || command -v "$ATRIUM_CLI" >/dev/null 2>&1 || exit 0

# Look up current pane name. Tolerate any failure silently — better to
# skip the nudge than to break the prompt cycle. Un-renamed panes store
# name "" (the header label is a UI fallback), so "no pane row" and
# "empty name" must be distinguished: gating on a non-empty name would
# silently skip exactly the unnamed panes the "" case-arm below exists
# to nudge.
PANE_JSON="$("$ATRIUM_CLI" pane list --filter "id=$ATRIUM_PANE_ID" --json 2>/dev/null || true)"
printf '%s' "$PANE_JSON" | jq -e '.[0]' >/dev/null 2>&1 || exit 0
PANE_NAME="$(printf '%s' "$PANE_JSON" | jq -r '.[0].name // ""' 2>/dev/null || true)"

# Generic launcher names we nudge against. Keep aligned with displayName
# fields in adapters/*/adapter.json. Empty string covers the case where
# a pane has no name at all. The python* entries cover adapters whose
# foreground process name is the interpreter, not the binary (Hermes is a
# Python app launched via a `hermes` wrapper, so atrium's process-name
# tracking labels the pane "python3.11" until the agent renames it).
case "$PANE_NAME" in
  "Claude Code"|"Codex"|"Codex CLI"|"Gemini"|"Gemini CLI"|"Grok"|"Antigravity"|"OpenCode"|"Pi"|"Cursor"|"Cursor Agent"|"Hermes"|"Terminal"|"python"|"Python"|"python3"|"python3."*|"")
    : # generic — fall through
    ;;
  *)
    exit 0
    ;;
esac

# Tight reminder — this lands in the prompt every turn until renamed, so
# token cost matters. Mirrors the guidance in atrium's CLAUDE.md.
read -r -d '' REMINDER <<'EOF' || true
[atrium] This pane is still using its default launcher name. Before responding, rename it to a 10–20 char description of the work:

  $ATRIUM_CLI_PATH pane rename "$ATRIUM_PANE_ID" --name "<new name>"

Front-load scannable bits ("Paste/drop refs", not "Refactoring paste/drop"), describe the work not your role, no status/timestamp/adapter name. If the user has already chosen a name, leave it alone.
EOF

build_envelope "$REMINDER"
exit 0

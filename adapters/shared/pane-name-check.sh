#!/usr/bin/env bash
# pane-name-check.sh — UserPromptSubmit hook entry that nudges the agent to
# rename its pane while it still carries a generic launcher name.
#
# Args:
#   $1  shape — one of: claude | codex | gemini | cursor (controls stdout
#       envelope shape; see context-entry.sh for analogous handling on
#       SessionStart)
#
# Behavior:
#   - Silent no-op outside atrium, when ATRIUM_PANE_ID is unset, when the
#     CLI is not reachable, or when the pane name is already non-generic.
#   - Otherwise emits a short instruction telling the agent to rename the
#     pane via `pane rename`, in the per-adapter context-injection envelope.
#
# Why no flag-file guard:
#   The reminder must fire on every prompt while the pane is still generic.
#   A "we already nudged" flag would let the agent skip the rename once
#   and silence future reminders — which is exactly the failure mode we're
#   trying to fix. Once the pane is renamed, the generic-name check fails
#   and the script exits silently, so the steady-state cost is one CLI
#   lookup per prompt.
#
# Escape hatch:
#   ATRIUM_PANE_RENAME_NUDGE=0 disables this nudge entirely. Intended for
#   power users who deliberately keep panes at their default names.

set -u

SHAPE="${1:?shape arg required (claude|codex|gemini|cursor)}"

[ -n "${ATRIUM:-}" ] || exit 0
[ -n "${ATRIUM_PANE_ID:-}" ] || exit 0
[ "${ATRIUM_PANE_RENAME_NUDGE:-1}" != "0" ] || exit 0

ATRIUM_CLI="${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}"
[ -x "$ATRIUM_CLI" ] || command -v "$ATRIUM_CLI" >/dev/null 2>&1 || exit 0

# Look up current pane name. Tolerate any failure silently — better to
# skip the nudge than to break the prompt cycle.
PANE_NAME="$("$ATRIUM_CLI" pane list --filter "id=$ATRIUM_PANE_ID" --json 2>/dev/null \
  | jq -r '.[0].name // empty' 2>/dev/null \
  || true)"

[ -n "$PANE_NAME" ] || exit 0

# Generic launcher names we nudge against. Keep aligned with displayName
# fields in adapters/*/adapter.json. Empty string covers the case where
# a pane has no name at all.
case "$PANE_NAME" in
  "Claude Code"|"Codex"|"Codex CLI"|"Gemini"|"Gemini CLI"|"Cursor"|"Cursor Agent"|"Terminal"|"")
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

case "$SHAPE" in
  claude|codex)
    # Stdout is appended to the user's prompt as additional context.
    printf '%s\n' "$REMINDER"
    ;;
  gemini)
    # Gemini: hookSpecificOutput.additionalContext — same envelope used
    # for SessionStart context injection in context-entry.sh. The
    # hookEventName mirrors the firing event (BeforeAgent for the
    # user-prompt-submit equivalent in gemini's hook taxonomy).
    jq -n --arg c "$REMINDER" \
      '{hookSpecificOutput: {hookEventName: "BeforeAgent", additionalContext: $c}}' 2>/dev/null || true
    ;;
  cursor)
    # Cursor: additional_context — same envelope used for SessionStart
    # context injection in context-entry.sh.
    jq -n --arg c "$REMINDER" \
      '{additional_context: $c}' 2>/dev/null || true
    ;;
  *)
    echo "pane-name-check.sh: unknown shape '$SHAPE'" >&2
    ;;
esac

exit 0

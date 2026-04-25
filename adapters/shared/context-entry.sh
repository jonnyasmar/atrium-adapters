#!/usr/bin/env bash
# context-entry.sh — shared SessionStart context-injection entry for adapters
# whose CLIs consume hook stdout as JSON (Gemini, Cursor).
#
# Args:
#   $1  shape — one of: gemini | cursor
#
# Why a script file rather than an inline shell command:
# - Cursor's shellExecutor was observed to silently drop multi-statement inline
#   pipelines, so cursor's adapter already routes through a binary-shaped
#   script (cursor-hook-entry.sh) — same posture here.
# - Gemini accepts inline commands fine but the jq invocation needs heavy
#   shell-quoting to coexist with the existing build_hook_command pattern;
#   keeping the logic in one file reads better and avoids drift between the
#   two adapters' wrapping shapes.
#
# Reads "${ATRIUM_DATA_DIR:-$HOME/.atrium}/agent-context.md", which is written
# at adapter install time by hooks.sh::install_context_file from the source
# at "../shared/atrium-context.md".
#
# Silent no-op outside atrium or when the context file is missing — emitting
# nothing on stdout is valid: both CLIs simply skip injection and continue.

set -u

SHAPE="${1:?shape arg required (gemini|cursor)}"

[ -n "${ATRIUM:-}" ] || exit 0
CTX_FILE="${ATRIUM_DATA_DIR:-$HOME/.atrium}/agent-context.md"
[ -f "$CTX_FILE" ] || exit 0

case "$SHAPE" in
  gemini)
    # Gemini: hookSpecificOutput.additionalContext (string).
    # Interactive: injected as the first turn in history.
    # Non-interactive: prepended to the user's prompt.
    # `hookEventName` mirrors the event type — every working example in
    # docs/hooks/writing-hooks.md carries it under hookSpecificOutput, even
    # though reference.md doesn't formally list it. Including it is the
    # safer side of the ambiguity.
    # Source: github.com/google-gemini/gemini-cli/docs/hooks/reference.md
    jq -n --rawfile content "$CTX_FILE" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $content}}' 2>/dev/null || true
    ;;
  cursor)
    # Cursor: additional_context (string) — appended to the session's
    # initial system context.
    # Source: cursor.com/docs/hooks
    jq -n --rawfile content "$CTX_FILE" \
      '{additional_context: $content}' 2>/dev/null || true
    ;;
  *)
    # Unknown shape — emit nothing rather than corrupt the host's expected
    # JSON envelope. Stderr is fine; CLIs typically log it as a warning.
    echo "context-entry.sh: unknown shape '$SHAPE'" >&2
    ;;
esac
exit 0

#!/usr/bin/env bash
# atrium-session-rules.sh — emit the Grok `--rules` payload on stdout.
#
# Released Grok builds before additionalContext support ignore passive hook
# stdout. Keep this launch-time fallback so those builds still receive atrium
# context and a one-shot pane-rename instruction. Newer builds also receive
# live event context from hooks.sh.
#
# Exit 0 always. Empty stdout is fine (caller skips --rules).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the copy installed under ATRIUM_DATA_DIR (what the running app uses);
# fall back to the sibling shared/ tree for repo-local tests and source checkouts.
CONTEXT_FILE=""
if [ -n "${ATRIUM_DATA_DIR:-}" ] && [ -f "${ATRIUM_DATA_DIR}/adapters/shared/atrium-context.md" ]; then
  CONTEXT_FILE="${ATRIUM_DATA_DIR}/adapters/shared/atrium-context.md"
elif [ -f "${SCRIPT_DIR}/../shared/atrium-context.md" ]; then
  CONTEXT_FILE="${SCRIPT_DIR}/../shared/atrium-context.md"
fi

if [ -n "$CONTEXT_FILE" ]; then
  cat "$CONTEXT_FILE"
  printf '\n\n'
fi

# Static pane-rename nudge. Grok can't re-nudge per turn (passive hooks), so
# this is a one-shot system-prompt instruction for the whole session. Mirrors
# the wording in adapters/shared/pane-name-check.sh.
cat <<'EOF'
[atrium] If this pane still uses its default launcher name ("Grok"), rename it to a 10–20 char description of the work before responding:

  $ATRIUM_CLI_PATH pane rename "$ATRIUM_PANE_ID" --name "<new name>"

Front-load scannable bits ("Paste/drop refs", not "Refactoring paste/drop"), describe the work not your role, no status/timestamp/adapter name. If the user has already chosen a name, leave it alone.
EOF

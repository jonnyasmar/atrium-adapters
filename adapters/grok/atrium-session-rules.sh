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

# Static pane-rename gate. Terminal Grok sessions cannot receive the native
# chat runtime's x.ai/interject reinforcement, so keep the same hard-gate
# wording in the launch-time system rules as the live provider.
cat <<'EOF'
[atrium] Do not answer the user's first request yet.

If this pane still uses a default launcher-assigned name, rename it now by running:

  $ATRIUM_CLI_PATH pane rename "$ATRIUM_PANE_ID" --name "<new name>"

Do not acknowledge, explain, or defer this instruction. Continue only after the command succeeds.

Use a 10–20 char work description. Front-load scannable bits ("Paste/drop refs", not "Refactoring paste/drop"); no status, timestamp, or adapter name. If the user explicitly chose the current title, leave it unchanged.
EOF

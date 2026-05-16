#!/usr/bin/env bash
set -euo pipefail

# Reads Claude Code's session retention setting (`cleanupPeriodDays`) from
# `~/.claude/settings.json` and emits it as JSON keyed by field name. Atrium
# calls this via the manifest `retention.readScript` to populate the
# retention chip in the adapter pane footer.
#
# Output schema: {"days": <integer>}
#
# Behavior on missing / malformed settings: emit the documented Claude
# default (30) so the chip still renders something sensible rather than
# erroring out.

SETTINGS="${HOME}/.claude/settings.json"
DEFAULT_DAYS=30

if [[ ! -f "$SETTINGS" ]]; then
  printf '{"days":%d}\n' "$DEFAULT_DAYS"
  exit 0
fi

# `// $DEFAULT_DAYS` falls back when the key is absent or null.
days="$(jq -r --argjson def "$DEFAULT_DAYS" '.cleanupPeriodDays // $def' "$SETTINGS" 2>/dev/null || printf '%d' "$DEFAULT_DAYS")"

# Guard against jq returning a non-integer (e.g. a string the user set by hand).
if ! [[ "$days" =~ ^[0-9]+$ ]]; then
  days="$DEFAULT_DAYS"
fi

printf '{"days":%d}\n' "$days"

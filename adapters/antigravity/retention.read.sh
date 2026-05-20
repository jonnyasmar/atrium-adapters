#!/usr/bin/env bash
set -euo pipefail

# Reads Antigravity CLI's session retention setting from
# `~/.gemini/antigravity-cli/settings.json` (Gemini-inherited shape:
# `general.sessionRetention.maxAge` + `maxCount`) and emits it as JSON
# keyed by field name. Atrium calls this via the manifest
# `retention.readScript` to populate the retention chip in the adapter
# pane footer.
#
# Output schema: {"days": <integer>, "maxCount": <integer>}
#
# Defaults match Gemini's documented defaults: 30 days, 100 sessions.

SETTINGS="${HOME}/.gemini/antigravity-cli/settings.json"
DEFAULT_DAYS=30
DEFAULT_MAX_COUNT=100

if [[ ! -f "$SETTINGS" ]]; then
  printf '{"days":%d,"maxCount":%d}\n' "$DEFAULT_DAYS" "$DEFAULT_MAX_COUNT"
  exit 0
fi

max_age_raw="$(jq -r '.general.sessionRetention.maxAge // empty' "$SETTINGS" 2>/dev/null || true)"
if [[ "$max_age_raw" =~ ^([0-9]+)d$ ]]; then
  days="${BASH_REMATCH[1]}"
else
  days="$DEFAULT_DAYS"
fi

max_count="$(jq -r --argjson def "$DEFAULT_MAX_COUNT" '.general.sessionRetention.maxCount // $def' "$SETTINGS" 2>/dev/null || printf '%d' "$DEFAULT_MAX_COUNT")"
if ! [[ "$max_count" =~ ^[0-9]+$ ]]; then
  max_count="$DEFAULT_MAX_COUNT"
fi

printf '{"days":%d,"maxCount":%d}\n' "$days" "$max_count"

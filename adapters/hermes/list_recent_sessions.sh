#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Hermes CLI sessions for a CWD.
# Reads ~/.hermes/state.db (SQLite) directly — a single indexed query, well
# under the adapter <50ms budget.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
DB="${HERMES_HOME:-$HOME/.hermes}/state.db"

command -v sqlite3 >/dev/null 2>&1 || { echo '{"sessions": []}'; exit 0; }
[ -f "$DB" ] || { echo '{"sessions": []}'; exit 0; }

ESC="${CWD//\'/\'\'}"
SQL="SELECT id,
            COALESCE(title, '')                 AS title,
            COALESCE(cwd, '')                    AS cwd,
            COALESCE(ended_at, started_at)       AS last_active
     FROM sessions
     WHERE source = 'cli' AND archived = 0 AND cwd = '${ESC}'
     ORDER BY last_active DESC
     LIMIT 10"

# -readonly first (avoids touching the WAL), fall back to a normal open.
RAW="$(sqlite3 -json -readonly "$DB" "$SQL" 2>/dev/null)" \
  || RAW="$(sqlite3 -json "$DB" "$SQL" 2>/dev/null)" \
  || { echo '{"sessions": []}'; exit 0; }

if [ -z "$RAW" ] || [ "$RAW" = "[]" ]; then
  echo '{"sessions": []}'
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  echo "$RAW" | jq --arg cwd "$CWD" --arg source_path "$DB" '
    [.[] | {
      id: (.id | tostring),
      name: (
        if (.title // "") != "" then
          (.title | if length > 80 then .[:77] + "..." else . end)
        else null end
      ),
      cwd: (if (.cwd // "") != "" then .cwd else $cwd end),
      lastActive: (
        if (.last_active | type) == "number"
        then (.last_active | floor | todate)
        else null end
      ),
      sourcePath: $source_path
    }] | {sessions: .}'
else
  echo "{\"sessions\": ${RAW}}"
fi

exit 0

#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Codex sessions for a CWD.
# Queries ~/.codex/state_5.sqlite via sqlite3 CLI.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
DB_PATH="${HOME}/.codex/state_5.sqlite"

# Graceful degradation if sqlite3 is unavailable
if ! command -v sqlite3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

# If database doesn't exist, return empty
if [ ! -f "$DB_PATH" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Query the database in JSON mode.
# sqlite3 -json returns an array of objects.
# We use a parameterized approach via printf to avoid SQL injection.
# sqlite3 does not support bound parameters in CLI, so we escape single quotes.
ESCAPED_CWD="${CWD//\'/\'\'}"

RAW="$(sqlite3 -json -readonly "$DB_PATH" \
  "SELECT id, cwd, title, updated_at, first_user_message FROM threads WHERE cwd = '${ESCAPED_CWD}' AND archived = 0 ORDER BY updated_at DESC LIMIT 10" 2>/dev/null)" || {
  echo '{"sessions": []}'
  exit 0
}

# If empty result or null
if [ -z "$RAW" ] || [ "$RAW" = "[]" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Transform with jq if available, otherwise use a simpler approach
if command -v jq &>/dev/null; then
  echo "$RAW" | jq --arg cwd "$CWD" '
    [.[] | {
      id: .id,
      name: (
        if (.title // "") != "" then .title
        elif (.first_user_message // "") != "" then
          (.first_user_message | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
           | if length > 50 then .[:47] + "..." else . end)
        else null end
      ),
      cwd: (.cwd // $cwd),
      lastActive: (.updated_at | tonumber | todate)
    }] | {sessions: .}'
else
  # Fallback: sqlite3 -json output is already JSON; wrap minimally
  # without jq we can't do name truncation, just pass through
  echo "{\"sessions\": ${RAW}}"
fi

exit 0

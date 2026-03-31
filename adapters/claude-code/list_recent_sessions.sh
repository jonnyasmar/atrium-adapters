#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Claude Code sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
ENCODED="-${CWD#/}"
ENCODED="${ENCODED//\//-}"
PROJECT_DIR="${HOME}/.claude/projects/${ENCODED}"

if [ ! -d "$PROJECT_DIR" ] || ! command -v jq &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

# Single stat → sort → top 20 (3 subprocesses total)
TOP="$(stat -f '%m %N' "$PROJECT_DIR"/*.jsonl 2>/dev/null | sort -rn | head -20)" || true
[ -z "$TOP" ] && { echo '{"sessions": []}'; exit 0; }

# Extract first user line from each file using a SINGLE awk process.
# Input: "mtime filepath" lines. Output: NDJSON with metadata.
# awk reads each file inline (getline) — no per-file subprocess.
echo "$TOP" | awk '
{
  mtime = $1
  filepath = $2
  # basename without extension
  n = split(filepath, parts, "/")
  bn = parts[n]
  sub(/\.jsonl$/, "", bn)

  # Read first user-type line from file (up to 50 lines)
  line = ""
  for (i = 0; i < 50; i++) {
    if ((getline raw < filepath) <= 0) break
    if (raw ~ /"type"/ && raw ~ /"user"/) {
      line = raw
      break
    }
  }
  close(filepath)

  # Output NDJSON entry
  if (line != "") {
    printf "{\"_b\":\"%s\",\"_m\":%s,\"_l\":%s}\n", bn, mtime, line
  } else {
    printf "{\"_b\":\"%s\",\"_m\":%s,\"_l\":null}\n", bn, mtime
  }
}' | jq -s --arg cwd "$CWD" '
  [.[] | {
    id: (if ._l then (._l.sessionId // ._b) else ._b end),
    name: (if ._l then
      (._l.message.content
        | if type == "string" then .
          elif type == "array" then ([.[] | select(.type == "text") | .text] | first // null)
          else null end
        | if . then (gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
            | if length > 50 then .[:47] + "..." else . end)
          else null end)
      else null end),
    cwd: (if ._l then (._l.cwd // $cwd) else $cwd end),
    lastActive: (._m | todate)
  }] | {sessions: .}'

exit 0

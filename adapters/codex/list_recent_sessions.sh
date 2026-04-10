#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Codex sessions for a CWD.
# First tries ~/.codex/sessions/ rollout JSONL files (Codex v0.118+),
# then falls back to ~/.codex/state_5.sqlite (older versions).
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
SESSIONS_DIR="${HOME}/.codex/sessions"
DB_PATH="${HOME}/.codex/state_5.sqlite"

# ── Strategy 1: Scan rollout JSONL files (Codex v0.118+) ──
# Session files: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
# First line of each file is session_meta with id, cwd, timestamp.
if [ -d "$SESSIONS_DIR" ] && command -v python3 &>/dev/null; then
  RESULT=$(python3 -c "
import json, os, glob, sys

cwd = sys.argv[1]
sessions_dir = sys.argv[2]
sessions = []

# Scan all rollout files (sorted by filename descending = newest first)
for path in sorted(glob.glob(os.path.join(sessions_dir, '*/*/*/rollout-*.jsonl')), reverse=True):
    if len(sessions) >= 20:
        break
    try:
        with open(path) as f:
            first_line = f.readline()
        meta = json.loads(first_line)
        if meta.get('type') != 'session_meta':
            continue
        payload = json.loads(meta['payload']) if isinstance(meta.get('payload'), str) else meta.get('payload', {})
        if payload.get('cwd') != cwd:
            continue
        sid = payload.get('id', '')
        if not sid:
            continue
        ts = payload.get('timestamp', meta.get('timestamp', ''))
        sessions.append({
            'id': sid,
            'name': None,
            'cwd': cwd,
            'lastActive': ts
        })
    except (json.JSONDecodeError, IOError, KeyError):
        continue

# Get first user message as name from history.jsonl
history_path = os.path.expanduser('~/.codex/history.jsonl')
if os.path.exists(history_path) and sessions:
    sid_set = {s['id'] for s in sessions}
    sid_names = {}
    try:
        with open(history_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                entry = json.loads(line)
                sid = entry.get('session_id', '')
                if sid in sid_set and sid not in sid_names:
                    text = entry.get('text', '')
                    if text:
                        sid_names[sid] = text[:80]
    except (json.JSONDecodeError, IOError):
        pass
    for s in sessions:
        if s['id'] in sid_names:
            s['name'] = sid_names[s['id']]

# Sort by lastActive descending, limit to 10
sessions.sort(key=lambda s: s.get('lastActive', ''), reverse=True)
print(json.dumps({'sessions': sessions[:10]}))
" "$CWD" "$SESSIONS_DIR" 2>/dev/null)

  if [ -n "$RESULT" ] && [ "$RESULT" != '{"sessions": []}' ]; then
    echo "$RESULT"
    exit 0
  fi
fi

# ── Strategy 2: SQLite fallback (older Codex versions) ──
if ! command -v sqlite3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

if [ ! -f "$DB_PATH" ]; then
  echo '{"sessions": []}'
  exit 0
fi

ESCAPED_CWD="${CWD//\'/\'\'}"

# Try -readonly first, fall back to normal open (macOS quarantine xattr)
RAW="$(sqlite3 -json -readonly "$DB_PATH" \
  "SELECT id, cwd, title, updated_at, first_user_message FROM threads WHERE cwd = '${ESCAPED_CWD}' AND archived = 0 ORDER BY updated_at DESC LIMIT 10" 2>/dev/null)" || \
RAW="$(sqlite3 -json "$DB_PATH" \
  "SELECT id, cwd, title, updated_at, first_user_message FROM threads WHERE cwd = '${ESCAPED_CWD}' AND archived = 0 ORDER BY updated_at DESC LIMIT 10" 2>/dev/null)" || {
  echo '{"sessions": []}'
  exit 0
}

if [ -z "$RAW" ] || [ "$RAW" = "[]" ]; then
  echo '{"sessions": []}'
  exit 0
fi

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
  echo "{\"sessions\": ${RAW}}"
fi

exit 0

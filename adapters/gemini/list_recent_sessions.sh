#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Gemini CLI sessions for a project.
# Args: CWD=$1
# Output: {"sessions": [{"id": "...", "name": "...", "cwd": "...", "lastActive": "..."}]}
#
# Gemini stores sessions at ~/.gemini/tmp/{project-name}/chats/session-*.json
# Project name is looked up from ~/.gemini/projects.json (maps path -> name).

CWD="${1:-.}"
GEMINI_DIR="${HOME}/.gemini"
PROJECTS_FILE="${GEMINI_DIR}/projects.json"

# If no projects file, return empty
if [ ! -f "$PROJECTS_FILE" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Find project name for CWD (try exact match first, then walk up)
PROJECT_NAME=""
search_dir="$CWD"
while [ "$search_dir" != "/" ]; do
  # Use python3 for reliable JSON parsing (available on macOS)
  PROJECT_NAME=$(python3 -c "
import json, sys
with open('$PROJECTS_FILE') as f:
    projects = json.load(f).get('projects', {})
name = projects.get('$search_dir', '')
print(name)
" 2>/dev/null)
  if [ -n "$PROJECT_NAME" ]; then
    break
  fi
  search_dir=$(dirname "$search_dir")
done

if [ -z "$PROJECT_NAME" ]; then
  echo '{"sessions": []}'
  exit 0
fi

SESSIONS_DIR="${GEMINI_DIR}/tmp/${PROJECT_NAME}/chats"
if [ ! -d "$SESSIONS_DIR" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Parse session files — read first 1000 bytes for performance
python3 -c "
import json, os, glob, sys

sessions_dir = '$SESSIONS_DIR'
cwd = '$CWD'
sessions = []

for path in glob.glob(os.path.join(sessions_dir, 'session-*.json')):
    try:
        with open(path, 'r') as f:
            content = f.read(4096)
        data = json.loads(content)
        sid = data.get('sessionId', '')
        if not sid:
            continue
        last_active = data.get('lastUpdated', data.get('startTime', ''))
        # Extract first user message as name
        name = None
        for msg in data.get('messages', []):
            if msg.get('type') == 'user':
                content_parts = msg.get('content', [])
                if isinstance(content_parts, list) and content_parts:
                    name = content_parts[0].get('text', '')[:80]
                elif isinstance(content_parts, str):
                    name = content_parts[:80]
                break
        sessions.append({
            'id': sid,
            'name': name,
            'cwd': cwd,
            'lastActive': last_active
        })
    except (json.JSONDecodeError, IOError, KeyError):
        continue

sessions.sort(key=lambda s: s.get('lastActive', ''), reverse=True)
sessions = sessions[:50]
print(json.dumps({'sessions': sessions}))
" 2>/dev/null || echo '{"sessions": []}'

exit 0

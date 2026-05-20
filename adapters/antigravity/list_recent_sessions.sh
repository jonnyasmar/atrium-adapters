#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Antigravity CLI (agy) sessions for a CWD.
# Args: CWD=$1
# Output: {"sessions": [{"id": "...", "name": "...", "cwd": "...", "lastActive": "..."}]}
#
# Antigravity stores per-session state across three files:
#   - ~/.gemini/antigravity-cli/conversations/<uuid>.pb
#       Protobuf conversation snapshot. Not parseable without the schema;
#       we use it only for mtime → lastActive.
#   - ~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl
#       JSONL transcript. First USER_INPUT entry gives us the display name
#       (inside <USER_REQUEST>...</USER_REQUEST>).
#   - ~/.gemini/antigravity-cli/cache/last_conversations.json
#       The only structured cwd→session mapping on disk:
#       { "<absolute-cwd>": "<latest-session-uuid>", ... }
#
# Because cwd→session attribution is only recorded for the latest session
# per workspace, this script can reliably surface at most one session
# per cwd. Older sessions exist as .pb files on disk but have no
# accessible workspace marker — they're omitted rather than misattributed.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
AGY_DIR="${HOME}/.gemini/antigravity-cli"
CACHE_FILE="${AGY_DIR}/cache/last_conversations.json"

if [ ! -f "$CACHE_FILE" ]; then
  echo '{"sessions": []}'
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

python3 - "$CWD" "$AGY_DIR" <<'PYEOF' 2>/dev/null || echo '{"sessions": []}'
import json, os, sys, re
from datetime import datetime, timezone

cwd = sys.argv[1]
agy_dir = sys.argv[2]
cache_file = os.path.join(agy_dir, "cache", "last_conversations.json")
conversations_dir = os.path.join(agy_dir, "conversations")
brain_dir = os.path.join(agy_dir, "brain")

try:
    with open(cache_file) as f:
        cache = json.load(f)
except (OSError, json.JSONDecodeError):
    print(json.dumps({"sessions": []}))
    sys.exit(0)

# Walk up cwd to find the most specific workspace match recorded in cache.
session_id = None
probe = cwd
while True:
    if probe in cache:
        session_id = cache[probe]
        break
    parent = os.path.dirname(probe)
    if parent == probe:
        break
    probe = parent

if not session_id:
    print(json.dumps({"sessions": []}))
    sys.exit(0)

pb_path = os.path.join(conversations_dir, f"{session_id}.pb")
transcript_path = os.path.join(
    brain_dir, session_id, ".system_generated", "logs", "transcript.jsonl"
)

last_active = ""
if os.path.isfile(pb_path):
    try:
        ts = os.path.getmtime(pb_path)
        last_active = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        pass

# Extract the first user prompt from <USER_REQUEST>...</USER_REQUEST>.
name = None
if os.path.isfile(transcript_path):
    try:
        with open(transcript_path) as f:
            for _ in range(20):
                line = f.readline()
                if not line:
                    break
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") != "USER_INPUT":
                    continue
                content = entry.get("content") or ""
                m = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", content, re.DOTALL)
                if m:
                    raw = m.group(1).strip()
                    raw = re.sub(r"\s+", " ", raw)
                    name = raw[:80] if raw else None
                    break
    except OSError:
        pass

print(json.dumps({"sessions": [{
    "id": session_id,
    "name": name,
    "cwd": cwd,
    "lastActive": last_active,
}]}))
PYEOF

exit 0

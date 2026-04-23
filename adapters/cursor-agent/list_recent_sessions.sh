#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Cursor Agent sessions for a CWD.
# Cursor stores chats at ~/.cursor/chats/<md5(realpath(cwd))>/<chatId>/store.db
# store.db has a `meta` table; key='0' holds hex-encoded JSON with agentId, name, createdAt.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
CHATS_ROOT="${HOME}/.cursor/chats"

if [ ! -d "$CHATS_ROOT" ]; then
  echo '{"sessions": []}'
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

python3 - "$CWD" "$CHATS_ROOT" <<'PY' 2>/dev/null || echo '{"sessions": []}'
import hashlib, json, os, sqlite3, sys, time

cwd, chats_root = sys.argv[1], sys.argv[2]

# Hash algorithm mirrors Cursor: md5(realpath(cwd))
try:
    resolved = os.path.realpath(cwd)
except OSError:
    resolved = cwd
workspace_hash = hashlib.md5(resolved.encode("utf-8")).hexdigest()

workspace_dir = os.path.join(chats_root, workspace_hash)
if not os.path.isdir(workspace_dir):
    print('{"sessions": []}')
    sys.exit(0)

sessions = []
for entry in os.listdir(workspace_dir):
    chat_dir = os.path.join(workspace_dir, entry)
    db_path = os.path.join(chat_dir, "store.db")
    if not os.path.isfile(db_path):
        continue
    try:
        mtime = os.path.getmtime(db_path)
    except OSError:
        continue

    chat_id = entry
    name = None
    created_at = None
    try:
        # Open read-only so a concurrently-running cursor-agent is not disturbed.
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.1)
        try:
            row = conn.execute("SELECT value FROM meta WHERE key='0'").fetchone()
        finally:
            conn.close()
        if row and row[0]:
            meta = json.loads(bytes.fromhex(row[0]).decode("utf-8"))
            chat_id = meta.get("agentId") or chat_id
            raw_name = meta.get("name") or None
            if raw_name:
                name = raw_name if len(raw_name) <= 80 else raw_name[:77] + "..."
            created_at = meta.get("createdAt")
    except (sqlite3.Error, ValueError, UnicodeDecodeError):
        pass

    # Prefer mtime (last-write) for lastActive; fall back to createdAt.
    ts = mtime if mtime else (created_at / 1000 if created_at else 0)
    last_active = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))

    sessions.append({
        "id": chat_id,
        "name": name,
        "cwd": cwd,
        "lastActive": last_active,
        "_mtime": mtime,
    })

sessions.sort(key=lambda s: s["_mtime"], reverse=True)
for s in sessions:
    s.pop("_mtime", None)

print(json.dumps({"sessions": sessions[:20]}))
PY

exit 0

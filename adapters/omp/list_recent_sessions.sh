#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Omp coding-agent sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}
#
# Omp stores sessions as JSONL files under ~/.omp/agent/sessions/, in
# cwd-encoded subdirectories. File layout (v3):
#   line 1: {"type":"title","title":"...","pad":...}
#   line 2: {"type":"session","id":"<uuid>","cwd":"/abs/path",...}
#   then:   {"type":"message","message":{"role":"user"|"assistant",...}}
# The session id for `omp --resume` is the id on the "session" line.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
SESSIONS_DIR="${OMP_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_SESSION_DIR:-${HOME}/.omp/agent/sessions}}"

if [ ! -d "$SESSIONS_DIR" ]; then
  echo '{"sessions": []}'
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

python3 - "$CWD" "$SESSIONS_DIR" <<'PYEOF' 2>/dev/null || echo '{"sessions": []}'
import json, os, sys, glob
from datetime import datetime, timezone

cwd = sys.argv[1]
sessions_dir = sys.argv[2]

def iso_from_mtime(path):
    try:
        return datetime.fromtimestamp(os.path.getmtime(path), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        return ""

def parse_head(path, max_lines=6):
    title = ""
    sid = ""
    file_cwd = ""
    try:
        with open(path) as f:
            for _ in range(max_lines):
                line = f.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = entry.get("type")
                if kind == "title":
                    t = entry.get("title") or ""
                    if isinstance(t, str):
                        title = t.strip()
                elif kind == "session":
                    sid = entry.get("id") or ""
                    file_cwd = entry.get("cwd") or ""
                if sid:
                    break
    except OSError:
        pass
    return title, sid, file_cwd

def first_user_message(path, max_lines=120):
    try:
        with open(path) as f:
            for _ in range(max_lines):
                line = f.readline()
                if not line:
                    return None
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = entry.get("message") if entry.get("type") == "message" else entry
                if not isinstance(msg, dict) or msg.get("role") != "user":
                    continue
                content = msg.get("content") or msg.get("text") or ""
                if isinstance(content, list):
                    parts = []
                    for c in content:
                        if isinstance(c, dict):
                            t = c.get("text") or c.get("content") or ""
                            if isinstance(t, str):
                                parts.append(t)
                        elif isinstance(c, str):
                            parts.append(c)
                    content = " ".join(parts)
                if isinstance(content, str) and content.strip():
                    return content.strip()[:80]
    except OSError:
        return None
    return None

sessions = []
seen_ids = set()

for path in glob.glob(os.path.join(sessions_dir, "**", "*.jsonl"), recursive=True):
    title, sid, file_cwd = parse_head(path)
    if not sid:
        sid = os.path.splitext(os.path.basename(path))[0]
    if sid in seen_ids:
        continue
    seen_ids.add(sid)

    if file_cwd and os.path.normpath(file_cwd) != os.path.normpath(cwd):
        continue

    sessions.append({
        "id": sid,
        "name": title or first_user_message(path),
        "cwd": cwd,
        "lastActive": iso_from_mtime(path),
    })

sessions.sort(key=lambda s: s.get("lastActive") or "", reverse=True)
print(json.dumps({"sessions": sessions[:20]}))
PYEOF

exit 0

#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Pi coding-agent sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}
#
# Pi stores sessions as JSONL files under ~/.pi/agent/sessions/, grouped
# by cwd. The exact directory layout is not formally documented; Pi's
# README describes "JSONL files with a tree structure, organized by
# working directory". This script:
#   1. Honors $PI_CODING_AGENT_SESSION_DIR if set (Pi's documented override).
#   2. Looks under ~/.pi/agent/sessions/ for files whose enclosing
#      directory matches the cwd via a metadata field on the first line.
#   3. Falls back to scanning every .jsonl under the sessions root if the
#      cwd-encoded directory layout isn't recognized.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
SESSIONS_DIR="${PI_CODING_AGENT_SESSION_DIR:-${HOME}/.pi/agent/sessions}"

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

def first_user_message(path, max_lines=80):
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
                role = entry.get("role") or entry.get("type")
                if role != "user":
                    continue
                content = entry.get("content") or entry.get("text") or ""
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

# Pi's tree-structured sessions: each session is one .jsonl file; the
# parent directory typically encodes the cwd. We walk anything under the
# sessions root and filter by cwd recorded on the first entry, falling
# back to mtime when the file has no cwd marker.
for path in glob.glob(os.path.join(sessions_dir, "**", "*.jsonl"), recursive=True):
    try:
        with open(path) as f:
            first = f.readline().strip()
    except OSError:
        continue
    sid = ""
    file_cwd = ""
    if first:
        try:
            head = json.loads(first)
            sid = head.get("sessionId") or head.get("id") or head.get("session_id") or ""
            file_cwd = head.get("cwd") or head.get("workingDirectory") or head.get("working_directory") or ""
        except json.JSONDecodeError:
            pass
    if not sid:
        # Fall back to the filename minus extension.
        sid = os.path.splitext(os.path.basename(path))[0]
    if sid in seen_ids:
        continue
    seen_ids.add(sid)

    # Skip files that explicitly belong to a different cwd. If the file
    # has no cwd marker, accept it — better to over-list than to drop
    # sessions silently.
    if file_cwd and file_cwd != cwd:
        continue

    sessions.append({
        "id": sid,
        "name": first_user_message(path),
        "cwd": cwd,
        "lastActive": iso_from_mtime(path),
        "sourcePath": path,
    })

sessions.sort(key=lambda s: s.get("lastActive") or "", reverse=True)
print(json.dumps({"sessions": sessions[:20]}))
PYEOF

exit 0

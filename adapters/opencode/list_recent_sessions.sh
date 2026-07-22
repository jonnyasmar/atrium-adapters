#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent OpenCode sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}
#
# OpenCode stores per-project session data under
# `~/.local/share/opencode/project/<project-encoded>/storage/session/info/`.
# Each session is a JSON file: `ses_<id>.json` (or similar) containing
# `id`, `title`, `time.created`, `time.updated`, plus a `messages` sibling
# dir for full conversation transcripts. Project encoding mirrors the
# absolute project path with `/` → a hash-safe slug.
#
# Schema details are inferred from the runtime — opencode does not publish
# a stable on-disk schema. This script is best-effort and falls back to
# returning an empty session list if the layout doesn't match.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
DATA_DIR="${HOME}/.local/share/opencode"

if [ ! -d "$DATA_DIR" ]; then
  echo '{"sessions": []}'
  exit 0
fi

if ! command -v python3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

python3 - "$CWD" "$DATA_DIR" <<'PYEOF' 2>/dev/null || echo '{"sessions": []}'
import json, os, sys, glob, re
from datetime import datetime, timezone

cwd = sys.argv[1]
data_dir = sys.argv[2]
sessions = []

# OpenCode hashes the project path into the directory name. We probe two
# common shapes: (a) project/<hash>/ where one of the project's metadata
# files records the absolute path, and (b) project/<path-encoded>/ where
# `/` is replaced with a safe separator. Scan everything under `project/`
# and pick directories whose recorded cwd matches.
projects_dir = os.path.join(data_dir, "project")
if not os.path.isdir(projects_dir):
    print(json.dumps({"sessions": []}))
    sys.exit(0)

candidate_dirs = []
for entry in os.listdir(projects_dir):
    full = os.path.join(projects_dir, entry)
    if not os.path.isdir(full):
        continue
    # Look for any project metadata file that names the cwd.
    matched = False
    for meta_name in ("project.json", "info.json", "meta.json"):
        meta_path = os.path.join(full, meta_name)
        if not os.path.isfile(meta_path):
            continue
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            if meta.get("path") == cwd or meta.get("cwd") == cwd or meta.get("root") == cwd:
                matched = True
                break
        except (OSError, json.JSONDecodeError):
            continue
    if matched:
        candidate_dirs.append(full)

# Fallback: if no metadata matched, scan every project dir and let
# downstream filtering handle it. Many opencode installs will only have
# one project so this is usually still correct.
if not candidate_dirs:
    candidate_dirs = [
        os.path.join(projects_dir, e)
        for e in os.listdir(projects_dir)
        if os.path.isdir(os.path.join(projects_dir, e))
    ]

def iso(ts):
    # Accept float seconds, int millis, or ISO strings.
    if isinstance(ts, (int, float)):
        # Heuristic: opencode stores Unix millis for `time.updated`.
        seconds = ts / 1000 if ts > 1e11 else ts
        return datetime.fromtimestamp(seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(ts, str) and ts:
        return ts
    return ""

for proj_dir in candidate_dirs:
    info_dir = os.path.join(proj_dir, "storage", "session", "info")
    if not os.path.isdir(info_dir):
        continue
    for path in glob.glob(os.path.join(info_dir, "*.json")):
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        sid = data.get("id") or os.path.splitext(os.path.basename(path))[0]
        if not sid:
            continue
        title = data.get("title") or data.get("name")
        time_block = data.get("time") or {}
        updated = time_block.get("updated") or data.get("updated") or time_block.get("created") or data.get("created")
        sessions.append({
            "id": sid,
            "name": title if title else None,
            "cwd": cwd,
            "lastActive": iso(updated),
            "sourcePath": path,
        })

sessions.sort(key=lambda s: s.get("lastActive") or "", reverse=True)
print(json.dumps({"sessions": sessions[:20]}))
PYEOF

exit 0

import os
from pathlib import Path
import sys

adapter = Path(__file__).resolve().parent
shared = adapter.parents[3] / 'shared' if adapter.parent.name == 'generations' and adapter.parents[2].name == '.managed' else adapter.parent / 'shared'
sys.path.insert(0, str(shared))
from session_lookup import PathIndex, component, fixture


def registry_path(home, sid):
    database = home / 'state_5.sqlite'
    if not database.is_file():
        return None
    import sqlite3

    connection = None
    try:
        connection = sqlite3.connect(database.absolute().as_uri() + '?mode=ro', uri=True, timeout=0)
        query = 'SELECT rollout_path FROM threads WHERE id = ?'
        plan = connection.execute('EXPLAIN QUERY PLAN ' + query, (sid,)).fetchall()
        if not any('SEARCH' in row[3] for row in plan):
            return None
        row = connection.execute(query, (sid,)).fetchone()
        if row and isinstance(row[0], str):
            path = Path(row[0])
            if path.is_absolute() and path.is_file():
                return path
    except (OSError, sqlite3.Error):
        pass
    finally:
        if connection:
            connection.close()
    return None


def legacy_path(home, sid):
    import glob
    import json

    for path in sorted(glob.glob(str(home / 'sessions/*/*/*/rollout-*.jsonl')), reverse=True):
        try:
            with open(path, encoding='utf-8', errors='replace') as stream:
                meta = json.loads(stream.readline())
            if not isinstance(meta, dict) or meta.get('type') != 'session_meta':
                continue
            payload = meta.get('payload')
            if isinstance(payload, str):
                payload = json.loads(payload)
            if isinstance(payload, dict) and payload.get('id') == sid:
                return Path(path)
        except (OSError, ValueError):
            continue
    return None


def find_transcript(sid, cwd=''):
    if not component(sid):
        return None
    testing, path = fixture(sid)
    if testing:
        return path
    home = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex')
    index = PathIndex('codex', [home])
    cached = index.get(sid)
    if cached:
        return cached
    path = registry_path(home, sid)
    if path is None:
        # Older sessions and incomplete native indexes still need discovery.
        path = legacy_path(home, sid)
    return index.put(sid, path) if path else None

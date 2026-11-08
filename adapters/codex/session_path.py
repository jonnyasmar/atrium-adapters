from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import re
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


def rollout_id(filename):
    match = re.fullmatch(r'rollout-.+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl', filename)
    return match[1] if match else None


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
    if path:
        return index.put(sid, path)
    import uuid

    try:
        identity = uuid.UUID(sid)
        if identity.version != 7:
            return None
        day = datetime.fromtimestamp((identity.int >> 80) / 1000, timezone.utc).date()
    except (ValueError, OverflowError, OSError):
        return None
    # UUIDv7 supplies the creation date, not the filename's timestamp. Probe
    # adjacent dates for a producer in another timezone; never walk partitions.
    for delta in (0, -1, 1):
        directory = home / 'sessions' / (day + timedelta(days=delta)).strftime('%Y/%m/%d')
        path = index.in_directory(directory, sid, rollout_id)
        if path:
            return path
    return None

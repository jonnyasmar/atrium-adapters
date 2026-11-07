import json
import math
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from sqlite_usage import count, main, usage_roots


REQUIRED_COLUMNS = {'id', 'session_id', 'type', 'time_created', 'time_updated', 'data'}


def data_directory():
    xdg = os.environ.get('XDG_DATA_HOME')
    base = Path(xdg).expanduser() if xdg else Path.home() / '.local' / 'share'
    return base / 'opencode'


def database_path():
    configured = os.environ.get('OPENCODE_DB')
    if configured == ':memory:':
        return None
    if configured:
        path = Path(configured)
        return path if path.is_absolute() else data_directory() / path
    return None


def database_files(root, recursive):
    if not root.is_dir():
        return []
    iterator = root.rglob('opencode*.db') if recursive else root.glob('opencode*.db')
    return [path for path in iterator if path.is_file()]


class OpenCodeUsage:
    def discover(self, since):
        test_root = os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT')
        if test_root:
            root = Path(test_root)
            if not root.is_absolute():
                raise ValueError('ATRIUM_TEST_TRANSCRIPT_ROOT must be absolute')
            candidates = database_files(root, True)
            return sorted(set(candidates), key=str)

        configured = database_path()
        candidates = []
        if configured is not None:
            candidates.append(configured)
        elif os.environ.get('OPENCODE_DB') != ':memory:':
            candidates.extend(database_files(data_directory(), False))
        for root in usage_roots():
            candidates.extend(database_files(root, True))
        return sorted({path for path in candidates if path and path.is_file()}, key=str)

    def has_usage_schema(self, conn):
        try:
            columns = {row['name'] for row in conn.execute('PRAGMA table_info(session_message)')}
            return REQUIRED_COLUMNS <= columns
        except sqlite3.Error:
            return False

    def select(self, conn, resume):
        reset = False
        timestamp = 0
        if resume is not None:
            try:
                kind, raw = resume.split(':', 1)
                if kind != 'r':
                    raise ValueError()
                timestamp = int(raw)
                if timestamp < 0:
                    raise ValueError()
            except ValueError:
                timestamp, reset = 0, True
        cursor = conn.execute(
            'SELECT id, session_id, type, time_created, time_updated, data '
            'FROM session_message WHERE time_updated >= ? ORDER BY time_updated, id',
            (timestamp,),
        )
        return cursor, reset

    def resume_after(self, row):
        return f"r:{int(row['time_updated'])}"

    def event(self, row, item):
        message_type = row['type']
        if message_type not in ('assistant', 'compaction'):
            return None
        try:
            data = json.loads(row['data'])
        except (TypeError, json.JSONDecodeError):
            raise ValueError('assistant/compaction data is invalid')
        if not isinstance(data, dict):
            raise ValueError('assistant/compaction data is not an object')
        if message_type == 'assistant':
            tokens = data.get('tokens')
            if tokens is None:
                return None
            if not isinstance(tokens, dict):
                raise ValueError('assistant tokens are invalid')
        elif message_type == 'compaction':
            if data.get('status') not in ('completed', 'failed'):
                return None
            tokens = data.get('tokens')
            if tokens is None:
                return None
            if not isinstance(tokens, dict):
                raise ValueError('compaction tokens are invalid')
        else:
            return None

        cache = tokens.get('cache') or {}
        if not isinstance(cache, dict):
            raise ValueError('token cache usage is invalid')
        reasoning = count(tokens.get('reasoning'))
        model = data.get('model') or {}
        if model and not isinstance(model, dict):
            raise ValueError('message model is invalid')
        model = model.get('id') if isinstance(model, dict) else None
        time_data = data.get('time')
        if time_data is not None and not isinstance(time_data, dict):
            raise ValueError('message time is invalid')
        created = time_data.get('created') if isinstance(time_data, dict) else None
        if created is None:
            created = row['time_created']
        if not isinstance(created, (int, float)) or isinstance(created, bool) or not math.isfinite(created):
            raise ValueError('message creation time is invalid')
        at = datetime.fromtimestamp(created / 1000, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        session = row['session_id']
        identity = row['id']
        if not isinstance(session, str) or not session or not isinstance(identity, str) or not identity:
            raise ValueError('assistant/compaction identity is invalid')
        visible_output = count(tokens.get('output'))
        return dict(
            type='usage',
            at=at,
            session_id=session,
            model=model if isinstance(model, str) and model else '__none',
            dedupe=identity,
            tokens=dict(
                input=count(tokens.get('input')),
                output=visible_output + reasoning,
                cache_read=count(cache.get('read')),
                cache_write_5m=count(cache.get('write')),
                cache_write_1h=0,
                reasoning=reasoning,
            ),
            tier=None,
            cost_usd=None,
            subagent=False,
            agent_id=None,
            fork_of=None,
        )


if __name__ == '__main__':
    sys.exit(main(OpenCodeUsage()))

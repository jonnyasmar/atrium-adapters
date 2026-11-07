import json
import math
import os
import sqlite3
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from sqlite_usage import count, main, usage_roots


REQUIRED_COLUMNS = {'id', 'session_id', 'type', 'seq', 'time_created', 'time_updated', 'data'}
SESSION_COLUMNS = {'id', 'fork_session_id', 'fork_boundary'}
LEGACY_COLUMNS = {'id', 'session_id', 'time_created', 'time_updated', 'data'}


class BoundedCache:
    def __init__(self, limit):
        self.limit = limit
        self.values = OrderedDict()

    def get(self, key):
        if key not in self.values:
            return False, None
        value = self.values.pop(key)
        self.values[key] = value
        return True, value

    def put(self, key, value):
        self.values.pop(key, None)
        self.values[key] = value
        if len(self.values) > self.limit:
            self.values.popitem(last=False)


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
    def __init__(self):
        self.connection = None
        self.legacy = False
        self.sessions = BoundedCache(512)
        self.parent_rows = BoundedCache(4096)

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
            session_columns = {row['name'] for row in conn.execute('PRAGMA table_info(session_v2)')}
            if REQUIRED_COLUMNS <= columns and SESSION_COLUMNS <= session_columns:
                self.legacy = False
                return True
            columns = {row['name'] for row in conn.execute('PRAGMA table_info(message)')}
            self.legacy = LEGACY_COLUMNS <= columns
            return self.legacy
        except sqlite3.Error:
            return False

    def select(self, conn, resume):
        self.connection = conn
        self.parent_rows = BoundedCache(4096)
        self.sessions = BoundedCache(512)
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
        if self.legacy:
            cursor = conn.execute(
                'SELECT id, session_id, time_created, time_updated, data '
                'FROM message WHERE time_updated >= ? ORDER BY time_updated, id',
                (timestamp,),
            )
        else:
            cursor = conn.execute(
                'SELECT id, session_id, type, seq, time_created, time_updated, data '
                'FROM session_message WHERE time_updated >= ? ORDER BY time_updated, id',
                (timestamp,),
            )
        return cursor, reset

    def resume_after(self, row):
        return f"r:{int(row['time_updated'])}"

    @staticmethod
    def fork_copy_seq(identity):
        if not isinstance(identity, str):
            return None
        prefix, separator, suffix = identity.rpartition('_')
        if not separator or not suffix.isdecimal() or (len(suffix) > 1 and suffix.startswith('0')):
            return None
        if not prefix.startswith('msg_'):
            return None
        native_id = prefix[4:]
        valid = (
            len(native_id) == 26
            and all(character in '0123456789abcdef' for character in native_id[:12])
            and all(character in '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' for character in native_id[12:])
        )
        return int(suffix) if valid else None

    @classmethod
    def is_fork_copy(cls, identity, seq):
        return (
            isinstance(seq, int) and not isinstance(seq, bool) and seq >= 0
            and cls.fork_copy_seq(identity) == seq
        )

    @classmethod
    def boundary_cutoff(cls, info):
        cutoff = info.get('boundary_seq')
        if isinstance(cutoff, int) and not isinstance(cutoff, bool):
            return cutoff
        return cls.fork_copy_seq(info.get('boundary_message_id'))

    def parent_row_id(self, session, seq):
        key = (session, seq)
        found, cached = self.parent_rows.get(key)
        if not found:
            row = self.connection.execute(
                'SELECT id FROM session_message WHERE session_id=? AND seq=?', key
            ).fetchone()
            cached = row['id'] if row else None
            self.parent_rows.put(key, cached)
        return cached

    def session_info(self, session):
        found, cached = self.sessions.get(session)
        if found:
            return cached
        row = self.connection.execute(
            'SELECT s.fork_session_id, s.fork_boundary, boundary.seq AS boundary_seq '
            'FROM session_v2 AS s LEFT JOIN session_message AS boundary '
            'ON boundary.session_id=s.fork_session_id '
            "AND boundary.id=json_extract(s.fork_boundary, '$.messageID') "
            'WHERE s.id=?',
            (session,),
        ).fetchone()
        if row is None:
            self.sessions.put(session, None)
            return None
        boundary = None
        if row['fork_boundary']:
            try:
                boundary = json.loads(row['fork_boundary'])
            except (TypeError, json.JSONDecodeError):
                boundary = None
        cached = dict(
            parent=row['fork_session_id'],
            boundary_type=boundary.get('type') if isinstance(boundary, dict) else None,
            boundary_message_id=boundary.get('messageID') if isinstance(boundary, dict) else None,
            boundary_seq=row['boundary_seq'],
        )
        self.sessions.put(session, cached)
        return cached

    def origin(self, identity, session, seq):
        original_session = session
        current_id = identity
        seen = set()
        while True:
            info = self.session_info(session)
            if info is None:
                if self.is_fork_copy(current_id, seq):
                    raise ValueError('forked message has no session metadata')
                return session, f'{session}:{seq}', None
            parent = info['parent']
            if not isinstance(parent, str) or not parent:
                return session, f'{session}:{seq}', None

            cutoff = self.boundary_cutoff(info)
            boundary_type = info['boundary_type']
            if isinstance(cutoff, int) and boundary_type in ('before', 'through'):
                inherited_by_boundary = seq < cutoff if boundary_type == 'before' else seq <= cutoff
            else:
                inherited_by_boundary = None
            inherited_by_id = self.is_fork_copy(current_id, seq)

            if inherited_by_boundary is False:
                if inherited_by_id:
                    raise ValueError('forked message ID conflicts with its stored boundary')
                return session, f'{session}:{seq}', None
            if inherited_by_boundary is None and not inherited_by_id:
                return session, f'{session}:{seq}', None

            if session in seen:
                raise ValueError('session fork ancestry contains a cycle')
            seen.add(session)
            parent_info = self.session_info(parent)
            if parent_info is None:
                return original_session, f'{parent}:{seq}', parent

            parent_id = self.parent_row_id(parent, seq)
            if parent_id is None:
                session, current_id = parent, None
                continue
            session, current_id = parent, parent_id

    def event(self, row, item):
        if self.legacy:
            return self.legacy_event(row)
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
        seq = row['seq']
        if (not isinstance(session, str) or not session or not isinstance(identity, str) or not identity
                or not isinstance(seq, int) or isinstance(seq, bool) or seq < 0):
            raise ValueError('assistant/compaction identity is invalid')
        origin_session, dedupe, fork_of = self.origin(identity, session, seq)
        visible_output = count(tokens.get('output'))
        return dict(
            type='usage',
            at=at,
            session_id=origin_session,
            model=model if isinstance(model, str) and model else '__none',
            dedupe=dedupe,
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
            fork_of=fork_of,
        )

    @staticmethod
    def legacy_event(row):
        data = json.loads(row['data'])
        if not isinstance(data, dict):
            raise ValueError('legacy message data is not an object')
        if data.get('role') != 'assistant':
            return None
        time_data = data.get('time')
        if not isinstance(time_data, dict):
            raise ValueError('legacy assistant time is invalid')
        completed = time_data.get('completed')
        if completed is None:
            return None
        created = time_data.get('created')
        if any(not isinstance(value, int) or isinstance(value, bool) or value < 0
               for value in (created, completed)):
            raise ValueError('legacy assistant time is not integer milliseconds')
        tokens = data.get('tokens')
        if tokens is None:
            return None
        if not isinstance(tokens, dict):
            raise ValueError('legacy assistant tokens are invalid')
        cache = tokens.get('cache') or {}
        if not isinstance(cache, dict):
            raise ValueError('legacy token cache usage is invalid')
        reasoning = count(tokens.get('reasoning'))
        normalized = dict(
            input=count(tokens.get('input')),
            output=count(tokens.get('output')) + reasoning,
            cache_read=count(cache.get('read')),
            cache_write_5m=count(cache.get('write')),
            cache_write_1h=0,
            reasoning=reasoning,
        )
        if not any(normalized.values()):
            return None
        session = row['session_id']
        if not isinstance(session, str) or not session:
            raise ValueError('legacy assistant session is invalid')
        model = data.get('modelID')
        model = model if isinstance(model, str) and model else '__none'
        vector = ':'.join(str(normalized[key]) for key in (
            'input', 'output', 'cache_read', 'cache_write_5m', 'reasoning'
        ))
        return dict(
            type='usage',
            at=datetime.fromtimestamp(created / 1000, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
            session_id=session,
            model=model,
            dedupe=f'opencode1:{created}:{model}:{vector}',
            tokens=normalized,
            tier=None,
            cost_usd=None,
            subagent=False,
            agent_id=None,
            fork_of=None,
        )


if __name__ == '__main__':
    sys.exit(main(OpenCodeUsage()))

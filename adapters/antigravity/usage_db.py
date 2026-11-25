import os
from pathlib import Path

from sqlite_usage import main, usage_roots
from usage_proto import usage, fields


class CompletedRows:
    def __init__(self, cursor):
        self.cursor = cursor
        self.done = False

    def fetchmany(self, size):
        if self.done:
            return []
        result = []
        for row in self.cursor.fetchmany(size):
            # A generating step can acquire counters later. Do not checkpoint
            # past it, including when later tool steps are already present.
            if row['status'] not in (3, 4, 5, 6, 7, 12):
                self.done = True
                break
            result.append(row)
        return result


class AntigravityDatabase:
    initial_resume = 'step:-1'

    def discover(self, since):
        fixture = os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT')
        roots = [Path(fixture)] if fixture else [
            Path.home() / '.gemini' / name / 'conversations'
            for name in ('antigravity-acp', 'antigravity-cli')]
        roots.extend(usage_roots())
        if not fixture and os.environ.get('ANTIGRAVITY_HOME'):
            home = Path(os.environ['ANTIGRAVITY_HOME']).expanduser()
            roots.extend((home, home / 'conversations'))
        seen = set()
        for root in roots:
            for path in ([root] if root.suffix == '.db' else root.glob('*.db')):
                path = path.absolute()
                if path not in seen:
                    seen.add(path)
                    yield path

    def has_usage_schema(self, conn):
        return {'idx', 'status', 'metadata'}.issubset(
            row[1] for row in conn.execute('PRAGMA table_info(steps)'))

    def select(self, conn, resume):
        self.connection = conn
        start, reset = -1, False
        if resume:
            try:
                prefix, raw = resume.split(':')
                start = int(raw)
                if prefix != 'step' or start < -1:
                    raise ValueError()
                last = conn.execute('SELECT idx FROM steps ORDER BY idx DESC LIMIT 1').fetchone()
                if last is None or start > last[0]:
                    start, reset = -1, True
            except (ValueError, TypeError):
                start, reset = -1, True
        return CompletedRows(conn.execute(
            'SELECT idx,status,metadata FROM steps WHERE idx>? ORDER BY idx', (start,))), reset

    def resume_after(self, row):
        return f"step:{row['idx']}"

    def event(self, row, item):
        def fallback(index):
            record = self.connection.execute('SELECT data FROM gen_metadata WHERE idx=?', (index,)).fetchone()
            if record is None:
                return ''
            return fields(fields(record[0]).get(1, b'')).get(19, b'').decode('utf-8')
        return usage(row['metadata'] or b'', Path(item['path']).stem, row['idx'], fallback)


def run(argv=None):
    return main(AntigravityDatabase(), argv)

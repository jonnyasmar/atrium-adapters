import contextlib
import io
import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ADAPTER = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ADAPTER))
spec = importlib.util.spec_from_file_location('antigravity_usage', ADAPTER / 'extract_session_usage.py')
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)
from usage_proto import usage
from usage_db import AntigravityDatabase


def vint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def proto(values):
    result = b''
    for number, value in values.items():
        if isinstance(value, int):
            result += vint(number << 3) + vint(value)
        else:
            result += vint(number << 3 | 2) + vint(len(value)) + value
    return result


def metadata(index=0, origin='synthetic', malformed=False):
    if malformed:
        return b'\xff'
    return proto({1: proto({1: 1795440247, 2: 126722000}),
                  9: proto({2: 120, 3: 40, 5: 500, 9: 10, 10: 30}),
                  20: proto({1: origin.encode(), 2: index}),
                  24: proto({8: b'gemini-4-neon-xhigh'})})


def create(path):
    conn = sqlite3.connect(path)
    conn.execute('CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,metadata BLOB)')
    return conn


def extract(path, resume=None):
    output = io.StringIO()
    request = dict(path=str(path), resume=resume)
    with contextlib.redirect_stdout(output):
        entry.extract_database(request, request, AntigravityDatabase(), 128)
    return [json.loads(line) for line in output.getvalue().splitlines()]


class DatabaseTests(unittest.TestCase):
    def test_initial_pending_step_resumes_without_a_false_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.db'
            conn = create(path)
            conn.execute('INSERT INTO steps VALUES(0,8,?)', (b'',))
            conn.commit()
            first = extract(path)[-1]
            self.assertEqual(first['resume'], 'step:-1')
            self.assertFalse(first['reset'])
            conn.execute('UPDATE steps SET status=3,metadata=? WHERE idx=0', (metadata(),))
            conn.commit()
            second = extract(path, first['resume'])[-1]
            self.assertEqual(second['events'], 1)
            self.assertFalse(second['reset'])
            conn.close()

    def test_verified_native_fields_are_disjoint_and_forks_keep_origin(self):
        event = usage(metadata(7), 'child', 18)
        self.assertEqual(event['tokens'], dict(input=120, output=40, cache_read=500,
                                              cache_write_5m=0, cache_write_1h=0, reasoning=10))
        self.assertEqual(event['at'], '2026-11-23T13:24:07.126Z')
        self.assertEqual(event['session_id'], 'synthetic')
        self.assertEqual(event['dedupe'], 'antigravity:synthetic:step:7')
        self.assertNotIn('cost_usd', event)

    def test_resume_stops_before_mutable_step_then_reads_its_final_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.db'
            conn = create(path)
            conn.executemany('INSERT INTO steps VALUES(?,?,?)',
                             [(0, 3, metadata()), (1, 8, b''), (2, 3, metadata(2))])
            conn.commit()
            first = extract(path)
            self.assertEqual(first[-1]['resume'], 'step:0')
            self.assertEqual(first[-1]['events'], 1)
            conn.execute('UPDATE steps SET status=3, metadata=? WHERE idx=1', (metadata(1),))
            conn.commit()
            second = extract(path, first[-1]['resume'])
            self.assertEqual(second[-1]['events'], 2)
            self.assertEqual(second[-1]['resume'], 'step:2')
            self.assertEqual(extract(path, 'step:2')[-1]['events'], 0)
            self.assertEqual(extract(path, 'invalid')[-1]['events'], 3)
            conn.close()

    def test_malformed_usage_is_visible_and_never_invented(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.db'
            conn = create(path)
            conn.executemany('INSERT INTO steps VALUES(?,?,?)',
                             [(0, 3, metadata(malformed=True)), (1, 3, metadata(1))])
            conn.commit()
            rows = extract(path)
            self.assertEqual(rows[-1]['malformed'], 1)
            self.assertEqual(rows[-1]['events'], 1)
            conn.close()

    def test_compaction_model_uses_generator_metadata_by_primary_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.db'
            conn = create(path)
            conn.execute('CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB)')
            conn.execute('INSERT INTO gen_metadata VALUES(7,?)',
                         (proto({1: proto({19: b'gemini-4-neon'})}),))
            step = proto({1: proto({1: 1795440247}), 9: proto({2: 120, 3: 40}),
                          20: proto({1: b'synthetic', 3: 7})})
            conn.execute('INSERT INTO steps VALUES(9,3,?)', (step,))
            conn.commit()
            event = extract(path)[0]
            self.assertEqual(event['model'], 'gemini-4-neon')
            self.assertEqual(event['dedupe'], 'antigravity:synthetic:step:0')
            conn.close()

    def test_scale_incremental_read_is_flat_at_10x_and_100x_sessions_and_steps(self):
        work = []
        for size in (10, 100, 1000):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for i in range(size):
                    (root / f'cold-{i}.db').touch()
                conn = create(root / 'active.db')
                conn.row_factory = sqlite3.Row
                conn.executemany('INSERT INTO steps VALUES(?,3,?)',
                                 ((i, metadata(i)) for i in range(size)))
                conn.commit()
                steps = [0]
                def tick():
                    steps[0] += 1
                    return 0
                conn.set_progress_handler(tick, 1)
                cursor, reset = AntigravityDatabase().select(conn, f'step:{size-2}')
                rows = cursor.fetchmany(128)
                work.append((steps[0], len(rows), sum(len(row['metadata']) for row in rows)))
                self.assertFalse(reset)
                plan = conn.execute('EXPLAIN QUERY PLAN SELECT idx,status,metadata FROM steps WHERE idx>? ORDER BY idx', (size-2,)).fetchall()
                self.assertTrue(all('SCAN' not in row[3] and 'TEMP B-TREE' not in row[3] for row in plan))
                conn.close()
        self.assertEqual([row[:2] for row in work], [work[0][:2]] * 3)
        self.assertLessEqual(max(row[2] for row in work), min(row[2] for row in work) + 1)


if __name__ == '__main__':
    unittest.main()

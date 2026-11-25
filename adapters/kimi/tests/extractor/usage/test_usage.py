import contextlib
import importlib.util
import io
import hashlib
import os
import subprocess
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ADAPTER = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('kimi_usage', ADAPTER / 'extract_session_usage.py')
kimi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kimi)
import extract_session_usage as shared


def extract(path, resume=None):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        shared.extract(dict(path=str(path), resume=resume), kimi.KimiUsage)
    return [json.loads(line) for line in output.getvalue().splitlines()]


class UsageTests(unittest.TestCase):
    def test_quick_session_lookup_uses_native_workspace_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            cwd = '/tmp/Invented Project'
            key = 'wd_invented-project_' + hashlib.sha256(cwd.encode()).hexdigest()[:12]
            path = Path(temporary) / 'sessions' / key / 'session-invented/agents/main/wire.jsonl'
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(dict(created_at=1795410000000)) + '\n')
            result = subprocess.run([sys.executable, str(ADAPTER/'extract_session.py'),
                '--session-id', 'session-invented', '--cwd', cwd], env={**os.environ,
                'ATRIUM_TEST_TRANSCRIPT_ROOT': temporary}, capture_output=True, text=True, check=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(rows[0]['session_id'], 'session-invented')
            self.assertEqual(rows[0]['started_at'], '2026-11-23T05:00:00+00:00')
            self.assertEqual(rows[-1]['event_count'], 2)

    def test_only_request_counters_are_read_and_replay_is_empty(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'session-invented/agents/main/wire.jsonl'
            path.parent.mkdir(parents=True)
            path.write_bytes((Path(__file__).parent/'native.jsonl').read_bytes())
            rows = extract(path)
            self.assertEqual(rows[-1]['events'], 1)
            self.assertEqual(rows[0]['session_id'], 'session-invented')
            self.assertEqual(rows[0]['tokens'], dict(input=200, output=80, cache_read=700,
                cache_write_5m=100, cache_write_1h=0, reasoning=0))
            self.assertEqual(extract(path, rows[-1]['resume'])[-1]['events'], 0)

    def test_scale_append_reads_one_request_with_10x_100x_sessions_and_history(self):
        work = []
        for size in (10, 100, 1000):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for number in range(size):
                    (root / f'cold-{number}.jsonl').write_text('{}\n')
                path = root / 'session-invented/agents/main/wire.jsonl'
                path.parent.mkdir(parents=True)
                path.write_text('{}\n' * size)
                cursor = extract(path)[-1]['resume']
                with path.open('ab') as source:
                    source.write((Path(__file__).parent/'native.jsonl').read_bytes().splitlines(keepends=True)[0])
                original = kimi.KimiUsage.event
                calls = []
                def observed(parser, row):
                    calls.append(1)
                    return original(parser, row)
                with patch.object(kimi.KimiUsage, 'event', observed):
                    rows = extract(path, cursor)
                self.assertEqual(rows[-1]['events'], 1)
                work.append(len(calls))
        self.assertEqual(work, [1, 1, 1])


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 - "$ADAPTER_DIR/extract_session.sh" "$FIXTURE_DIR" <<'PY'
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

script = Path(sys.argv[1])
fixture_root = Path(sys.argv[2])
sys.path.insert(0, str(script.parent.parent / 'shared'))
from extract_session_usage import fold
import extract_session_usage as shared_usage

session = 'synthetic-grok-session-716'
source = fixture_root / session / 'updates.jsonl'
fork = fixture_root / 'synthetic-grok-fork-716' / 'updates.jsonl'
expected = [json.loads(line) for line in (fixture_root / 'expected.jsonl').read_text().splitlines()]


def invoke(mode, requests=None, extra_env=None):
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    completed = subprocess.run(
        [str(script), '--usage', mode],
        input=''.join(json.dumps(request) + '\n' for request in (requests or [])),
        text=True,
        capture_output=True,
        env=env,
        check=True,
        timeout=10,
    )
    return [json.loads(line) for line in completed.stdout.splitlines()]


request = {'path': str(source), 'session_id': session, 'resume': None}
full = invoke('--batch', [request])
events = [row for row in full if row['type'] == 'usage']
checkpoint = full[-1]
assert events == expected, (events, expected)
assert checkpoint['type'] == 'checkpoint'
assert checkpoint['events'] == len(expected) and checkpoint['malformed'] == 0
assert checkpoint['complete'] is True
assert 'unrecorded' not in checkpoint
print('[PASS] response usage golden, duplicate fold, ordinal fallback, aggregate ignored')

fork_copy = invoke('--batch', [{'path': str(fork), 'session_id': 'synthetic-grok-fork-716'}])
fork_events = [row for row in fork_copy if row['type'] == 'usage']
assert len(fork_events) == 1 and fork_events[0]['dedupe'] == expected[1]['dedupe'], fork_events
folded_copy = fold(expected[1], fork_events[0])
assert folded_copy == expected[1], folded_copy
print('[PASS] fork copy keeps eventId and folds to the original response')

lines = source.read_bytes().splitlines(keepends=True)
expected_keys = {row['dedupe'] for row in expected}
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for boundary in range(len(lines) + 1):
        prefix = root / f'prefix-{boundary}.jsonl'
        prefix.write_bytes(b''.join(lines[:boundary]))
        first = invoke('--batch', [{'path': str(prefix), 'session_id': session, 'resume': None}])
        token = first[-1]['resume']
        rest = invoke('--batch', [{'path': str(source), 'session_id': session, 'resume': token}])
        combined_keys = {row['dedupe'] for row in first + rest if row['type'] == 'usage'}
        assert combined_keys == expected_keys, (boundary, combined_keys, expected_keys)
print(f'[PASS] resume at all {len(lines) + 1} line boundaries')

for name, count_expected, requests_expected in (
    ('legacy-only.jsonl', 1, 0),
    ('mixed-history.jsonl', 1, 1),
    ('modern-only.jsonl', 0, 2),
    ('empty-turns.jsonl', 0, 0),
    ('model-call-only.jsonl', 1, 0),
    ('cost-only.jsonl', 1, 0),
):
    path = fixture_root / name
    result = invoke('--batch', [{'path': str(path), 'resume': None}])
    assert len([row for row in result if row['type'] == 'usage']) == requests_expected
    expected_unrecorded = {'reason': 'legacy-turn-totals', 'count': 1} if count_expected else None
    assert result[-1].get('unrecorded') == expected_unrecorded, (name, result)
    assert result[-1]['complete'] is True and 'error' not in result[-1]
    lines = path.read_bytes().splitlines(keepends=True)
    with tempfile.TemporaryDirectory() as temporary:
        prefix = Path(temporary) / 'updates.jsonl'
        for boundary in range(len(lines) + 1):
            prefix.write_bytes(b''.join(lines[:boundary]))
            first = invoke('--batch', [{'path': str(prefix), 'resume': None}])
            resumed = invoke('--batch', [{'path': str(path), 'resume': first[-1]['resume']}])
            assert resumed[-1].get('unrecorded') == expected_unrecorded, (name, boundary, resumed)
            assert resumed[-1]['complete'] is True and 'error' not in resumed[-1]
print('[PASS] legacy/mixed histories retain counted notes across resumes; modern and empty/zero aggregates stay covered')

compress = None
try:
    from compression import zstd
    compress = zstd.compress
except ImportError:
    try:
        import zstandard
        compress = zstandard.ZstdCompressor().compress
    except ImportError:
        pass
if compress:
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / 'updates.jsonl.zst'
        archive.write_bytes(compress((fixture_root / 'mixed-history.jsonl').read_bytes()))
        first = invoke('--batch', [{'path': str(archive), 'resume': None}])
        resumed = invoke('--batch', [{'path': str(archive), 'resume': first[-1]['resume']}])
        assert resumed[-1]['events'] == 0 and resumed[-1]['complete'] is True
        assert first[-1]['unrecorded'] == {'reason': 'legacy-turn-totals', 'count': 1}
        assert 'unrecorded' not in resumed[-1]
        assert resumed[-1]['resume'] == first[-1]['resume'] and resumed[-1]['reset'] is False

        def unexpected_parser(*_args):
            raise AssertionError('unchanged archive constructed a parser')

        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(
            shared_usage, 'open_transcript', side_effect=AssertionError('unchanged archive was decompressed')
        ):
            shared_usage.extract({'path': str(archive), 'resume': first[-1]['resume']}, unexpected_parser)
        assert json.loads(output.getvalue()) == resumed[-1]
    print('[PASS] unchanged compressed history is a true no-op: no parser, decompression, usage, or optional diagnostics')

with tempfile.TemporaryDirectory() as temporary:
    torn = Path(temporary) / 'updates.jsonl'
    torn.write_bytes(source.read_bytes() + b'{"timestamp":1794000006,"method":"_x.ai/session/update"}')
    result = invoke('--batch', [{'path': str(torn), 'session_id': session, 'resume': None}])
    assert [row for row in result if row['type'] == 'usage'] == expected
    assert result[-1]['complete'] is True and result[-1]['malformed'] == 0
    assert result[-1]['resume'].startswith(f'o:{source.stat().st_size}:')
print('[PASS] partial tail is deferred without advancing the checkpoint')

listed = invoke('--list', extra_env={'ATRIUM_TEST_TRANSCRIPT_ROOT': str(fixture_root)})
assert {row['path'] for row in listed} == {str(source), str(fork)}, listed
assert {row['session_id'] for row in listed} == {session, 'synthetic-grok-fork-716'}, listed
print('[PASS] discovery includes updates.jsonl and excludes chat_history.jsonl')

requests = [request] * 200
started = time.perf_counter()
batch = invoke('--batch', requests)
elapsed = time.perf_counter() - started
assert len([row for row in batch if row['type'] == 'checkpoint']) == 200
assert elapsed / 200 <= 0.05, f'{elapsed * 1000 / 200:.3f} ms/file'
print(f'[PASS] one 200-file batch: {elapsed * 1000 / 200:.3f} ms/file')
PY

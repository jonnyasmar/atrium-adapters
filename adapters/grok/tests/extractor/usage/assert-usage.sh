#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 - "$ADAPTER_DIR/extract_session.sh" "$FIXTURE_DIR" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

script = Path(sys.argv[1])
fixture_root = Path(sys.argv[2])
session = 'synthetic-grok-session-716'
source = fixture_root / session / 'updates.jsonl'
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
print('[PASS] response usage golden, duplicate fold, ordinal fallback, aggregate ignored')

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

with tempfile.TemporaryDirectory() as temporary:
    torn = Path(temporary) / 'updates.jsonl'
    torn.write_bytes(source.read_bytes() + b'{"timestamp":1794000006,"method":"_x.ai/session/update"}')
    result = invoke('--batch', [{'path': str(torn), 'session_id': session, 'resume': None}])
    assert [row for row in result if row['type'] == 'usage'] == expected
    assert result[-1]['complete'] is True and result[-1]['malformed'] == 0
    assert result[-1]['resume'].startswith(f'o:{source.stat().st_size}:')
print('[PASS] partial tail is deferred without advancing the checkpoint')

listed = invoke('--list', extra_env={'ATRIUM_TEST_TRANSCRIPT_ROOT': str(fixture_root)})
assert len(listed) == 1, listed
assert listed[0]['path'] == str(source)
assert listed[0]['session_id'] == session
print('[PASS] discovery includes updates.jsonl and excludes chat_history.jsonl')

requests = [request] * 200
started = time.perf_counter()
batch = invoke('--batch', requests)
elapsed = time.perf_counter() - started
assert len([row for row in batch if row['type'] == 'checkpoint']) == 200
assert elapsed / 200 <= 0.05, f'{elapsed * 1000 / 200:.3f} ms/file'
print(f'[PASS] one 200-file batch: {elapsed * 1000 / 200:.3f} ms/file')
PY

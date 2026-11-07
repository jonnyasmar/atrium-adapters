#!/usr/bin/env bash
set -euo pipefail
ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 "$ADAPTER_DIR/../shared/extract_session_usage_test.py" "$ADAPTER_DIR"
python3 - "$ADAPTER_DIR" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys

adapter = Path(sys.argv[1])
fixture = adapter / 'tests/extractor/usage'
assert 'usage' not in json.loads((adapter / 'adapter.json').read_text())['sessionExtractor']
env = dict(os.environ, ATRIUM_TEST_TRANSCRIPT_ROOT=str(fixture / 'input'))
command = ['bash', str(adapter / 'extract_session.sh'), '--usage']
def run(*args, data=''):
    return subprocess.run(command + list(args), input=data, text=True,
                          capture_output=True, env=env, check=True)
listed = [json.loads(line) for line in run('--list').stdout.splitlines()]
assert {row['session_id'] for row in listed} == {'invented-session', 'invented-live-decoy'}
for row in listed:
    path = Path(row['path'])
    assert path.is_absolute() and row['size'] == path.stat().st_size
    assert row['mtime'] == int(path.stat().st_mtime)
assert not run('--list', '--since', '9999999999').stdout
requests = ''.join(json.dumps(dict(path=row['path'], session_id=None, resume=None)) + '\n' for row in listed)
rows = [json.loads(line) for line in run('--batch', data=requests).stdout.splitlines()]
assert len(rows) == len(listed) == 2
assert [row['path'] for row in rows] == [row['path'] for row in listed]
assert all(row['type'] == 'checkpoint' and row['complete'] and row['events'] == 0
           and row['malformed'] == 0 for row in rows)
assert not run('--batch').stdout
print(f'{adapter.name}: unsupported manifest, discovery metadata/filter, ordered zero-usage checkpoints, empty batch passed')
PYTEST

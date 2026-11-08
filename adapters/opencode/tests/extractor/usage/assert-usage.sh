#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 - "$ADAPTER_DIR/extract_session.sh" "$FIXTURE_DIR" <<'PY'
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

script = Path(sys.argv[1])
fixtures = Path(sys.argv[2])
expected = [json.loads(line) for line in (fixtures / 'expected.jsonl').read_text().splitlines()]


def build(path):
    subprocess.run([sys.executable, str(fixtures / 'build_fixture.py'), str(path)], check=True)


def invoke(mode, requests=None, env=None, extra_args=()):
    child_env = dict(os.environ)
    for key in ('XDG_DATA_HOME', 'OPENCODE_DB', 'OPENCODE_CHANNEL', 'ATRIUM_TEST_TRANSCRIPT_ROOT', 'ATRIUM_USAGE_ROOTS'):
        child_env.pop(key, None)
    if env:
        child_env.update(env)
    completed = subprocess.run(
        [str(script), '--usage', mode, *extra_args],
        input=''.join(json.dumps(request) + '\n' for request in (requests or [])),
        text=True,
        capture_output=True,
        env=child_env,
        check=True,
        timeout=10,
    )
    return [json.loads(line) for line in completed.stdout.splitlines()]


primary_temporary = tempfile.TemporaryDirectory()
primary_database = Path(primary_temporary.name) / 'opencode.db'
build(primary_database)
initial_digest = hashlib.sha256(primary_database.read_bytes()).hexdigest()
request = {'path': str(primary_database), 'resume': None}
full = invoke('--batch', [request], extra_args=('--page-size', '2'))
events = [row for row in full if row['type'] == 'usage']
assert events == expected, (events, expected)
assert full[-1]['events'] == len(expected) and full[-1]['malformed'] == 0
assert full[-1]['complete'] is True and full[-1]['resume'].startswith('r:')
assert hashlib.sha256(primary_database.read_bytes()).hexdigest() == initial_digest
print('[PASS] assistant and completed/failed compaction usage golden; read-only database')

expected_keys = {row['dedupe'] for row in expected}
all_rows = sqlite3.connect(primary_database)
boundaries = [row[0] for row in all_rows.execute('SELECT DISTINCT time_updated FROM session_message ORDER BY time_updated')]
all_rows.close()
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for index, boundary in enumerate([0, *boundaries]):
        prefix = root / f'prefix-{index}.db'
        build(prefix)
        with sqlite3.connect(prefix) as connection:
            connection.execute('DELETE FROM session_message WHERE time_updated > ?', (boundary,))
        first = invoke('--batch', [{'path': str(prefix), 'resume': None}])
        token = first[-1]['resume']
        rest = invoke('--batch', [{'path': str(primary_database), 'resume': token}])
        keys = {row['dedupe'] for row in first + rest if row['type'] == 'usage'}
        assert keys == expected_keys, (boundary, keys, expected_keys)
print(f'[PASS] inclusive resume across {len(boundaries) + 1} timestamp boundaries, including ties')

with tempfile.TemporaryDirectory() as temporary:
    updated = Path(temporary) / 'updated.db'
    build(updated)
    first = invoke('--batch', [{'path': str(updated), 'resume': None}])
    resume = first[-1]['resume']
    with sqlite3.connect(updated) as connection:
        row = connection.execute("SELECT data FROM session_message WHERE id='msg_synthetic_assistant_001'").fetchone()
        data = json.loads(row[0])
        data['tokens']['input'] = 250
        connection.execute(
            "UPDATE session_message SET data=?, time_updated=1794000007000 WHERE id='msg_synthetic_assistant_001'",
            (json.dumps(data),),
        )
    resumed = invoke('--batch', [{'path': str(updated), 'resume': resume}])
    changed = [row for row in resumed if row.get('dedupe') == 'ses_synthetic_opencode_716:1']
    assert len(changed) == 1 and changed[0]['tokens']['input'] == 250
    assert resumed[-1]['resume'] == 'r:1794000007000'
print('[PASS] updated rows are recovered by the inclusive timestamp cursor')

with tempfile.TemporaryDirectory() as temporary:
    fork_database = Path(temporary) / 'opencode-forks.db'
    subprocess.run([sys.executable, str(fixtures / 'build_fork_fixture.py'), str(fork_database)], check=True)
    fork_result = invoke('--batch', [{'path': str(fork_database), 'resume': None}], extra_args=('--page-size', '64'))
    fork_events = [row for row in fork_result if row['type'] == 'usage']
    by_key = {row['dedupe']: row for row in fork_events}
    expected_fork_keys = {
        'ses_fork_parent:1',
        'ses_fork_child:2',
        'ses_deleted_parent:1',
        'ses_surviving_grandparent:1',
        'ses_deleted_intermediate:1',
    }
    assert set(by_key) == expected_fork_keys, (by_key, expected_fork_keys)
    assert by_key['ses_fork_parent:1']['session_id'] == 'ses_fork_parent'
    assert by_key['ses_fork_parent:1']['fork_of'] is None
    assert by_key['ses_fork_child:2']['session_id'] == 'ses_fork_child'
    assert by_key['ses_deleted_parent:1']['fork_of'] == 'ses_deleted_parent'
    assert by_key['ses_deleted_parent:1']['session_id'] == 'ses_sibling_a'
    assert by_key['ses_deleted_intermediate:1']['fork_of'] == 'ses_deleted_intermediate'
    assert by_key['ses_deleted_intermediate:1']['session_id'] == 'ses_grandchild_after_delete'
    assert by_key['ses_surviving_grandparent:1']['tokens'] == by_key['ses_deleted_intermediate:1']['tokens']
    assert fork_result[-1]['complete'] is True and fork_result[-1]['malformed'] == 0
print('[PASS] present ancestry resolves to origin; deleted-parent siblings fold; deleted intermediate retains disclosed duplicate marker')

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    data = root / 'xdg' / 'opencode'
    data.mkdir(parents=True)
    database = data / 'opencode.db'
    connection = sqlite3.connect(database)
    connection.execute('PRAGMA journal_mode=WAL')
    connection.executescript((fixtures / 'fixture.sql').read_text())
    wal = Path(str(database) + '-wal')
    assert wal.exists() and wal.stat().st_size > 0
    listed = invoke('--list', env={'XDG_DATA_HOME': str(root / 'xdg')})
    assert len(listed) == 1 and listed[0]['path'] == str(database)
    assert listed[0]['size'] == database.stat().st_size + wal.stat().st_size
    future = max(database.stat().st_mtime, wal.stat().st_mtime) + 10
    assert invoke('--list', env={'XDG_DATA_HOME': str(root / 'xdg')}, extra_args=('--since', str(future))) == []
    wal_request = {'path': str(database), 'resume': None}
    wal_events = invoke('--batch', [wal_request])
    assert [row for row in wal_events if row['type'] == 'usage'] == expected
    connection.close()
print('[PASS] list accounts for WAL size/mtime and read-only extraction sees WAL content')

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    default_data = root / 'xdg' / 'opencode'
    test_root = root / 'test-fixtures'
    extra_root = root / 'explicit-extra'
    default_data.mkdir(parents=True)
    test_root.mkdir()
    extra_root.mkdir()
    default_db = default_data / 'opencode.db'
    fixture_db = test_root / 'opencode-test.db'
    extra_db = extra_root / 'opencode-extra.db'
    build(default_db)
    build(fixture_db)
    build(extra_db)
    test_listing = invoke('--list', env={
        'XDG_DATA_HOME': str(root / 'xdg'),
        'ATRIUM_TEST_TRANSCRIPT_ROOT': str(test_root),
    })
    assert [row['path'] for row in test_listing] == [str(fixture_db)]
    extras_listing = invoke('--list', env={
        'XDG_DATA_HOME': str(root / 'xdg'),
        'ATRIUM_USAGE_ROOTS': json.dumps([str(extra_root)]),
    })
    assert {row['path'] for row in extras_listing} == {str(default_db), str(extra_db)}
    memory_listing = invoke('--list', env={
        'XDG_DATA_HOME': str(root / 'xdg'),
        'OPENCODE_DB': ':memory:',
    })
    assert memory_listing == []
    memory_with_extra = invoke('--list', env={
        'XDG_DATA_HOME': str(root / 'xdg'),
        'OPENCODE_DB': ':memory:',
        'ATRIUM_USAGE_ROOTS': json.dumps([str(extra_root)]),
    })
    assert [row['path'] for row in memory_with_extra] == [str(extra_db)]
    build(default_data / 'opencode-extra.db')
    relative_override = invoke('--list', env={
        'XDG_DATA_HOME': str(root / 'xdg'),
        'OPENCODE_DB': 'opencode-extra.db',
    })
    assert [row['path'] for row in relative_override] == [str(default_data / 'opencode-extra.db')]
    invalid_roots = subprocess.run(
        [str(script), '--usage', '--list'],
        text=True,
        capture_output=True,
        env={**{key: value for key, value in os.environ.items() if key not in (
            'XDG_DATA_HOME', 'OPENCODE_DB', 'OPENCODE_CHANNEL', 'ATRIUM_TEST_TRANSCRIPT_ROOT', 'ATRIUM_USAGE_ROOTS'
        )}, 'ATRIUM_USAGE_ROOTS': json.dumps(['relative/path'])},
    )
    assert invalid_roots.returncode == 10
print('[PASS] test root overrides defaults; explicit roots, :memory:, and OPENCODE_DB are honored')

with tempfile.TemporaryDirectory() as temporary:
    legacy = Path(temporary) / 'legacy.db'
    with sqlite3.connect(legacy) as connection:
        connection.execute('CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
    result = invoke('--batch', [{'path': str(legacy), 'resume': 'r:123'}])
    assert not [row for row in result if row['type'] == 'usage']
    assert result[-1]['complete'] is True and result[-1]['resume'] == 'unsupported-schema'
    assert result[-1]['unrecorded'] == {'reason': 'unsupported-schema', 'count': 1}
    assert 'error' not in result[-1]
    resumed = invoke('--batch', [{'path': str(legacy), 'resume': result[-1]['resume']}])
    assert resumed[-1] == result[-1]
    with sqlite3.connect(legacy) as connection:
        connection.executescript((fixtures / 'fixture.sql').read_text())
    recovered = invoke('--batch', [{'path': str(legacy), 'resume': result[-1]['resume']}])
    assert [row for row in recovered if row['type'] == 'usage'] == expected
    assert recovered[-1]['complete'] is True and recovered[-1]['reset'] is True
    assert 'unrecorded' not in recovered[-1]
print('[PASS] readable unsupported schema finishes with one unrecorded history and a stable sentinel')

with tempfile.TemporaryDirectory() as temporary:
    corrupt = Path(temporary) / 'corrupt.db'
    corrupt.write_bytes(b'invented bytes that are not a SQLite database')
    result = invoke('--batch', [{'path': str(corrupt), 'resume': 'r:123'}])
    assert result[-1]['complete'] is False and result[-1]['resume'] == 'r:123'
    assert result[-1]['error'] == 'DatabaseError' and 'unrecorded' not in result[-1]
print('[PASS] corrupt SQLite remains an incomplete read failure, never unsupported history')

legacy_expected = [json.loads(line) for line in (fixtures / 'legacy_expected.jsonl').read_text().splitlines()]
with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / 'opencode-legacy.db'
    subprocess.run([sys.executable, str(fixtures / 'build_legacy_fixture.py'), str(database)], check=True)
    original_digest = hashlib.sha256(database.read_bytes()).hexdigest()
    result = invoke('--batch', [{'path': str(database), 'resume': None}], extra_args=('--page-size', '64'))
    legacy_events = [row for row in result if row['type'] == 'usage']
    assert legacy_events == legacy_expected, (legacy_events, legacy_expected)
    assert result[-1]['complete'] is True and result[-1]['malformed'] == 0
    assert hashlib.sha256(database.read_bytes()).hexdigest() == original_digest
    assert sum(row['tokens']['input'] for row in legacy_events) == 311
    assert sum(row['tokens']['output'] for row in legacy_events) == 73
    assert all(row['fork_of'] is None and row['cost_usd'] is None for row in legacy_events)
    paged = invoke('--batch', [{'path': str(database), 'resume': None}], extra_args=('--page-size', '1'))
    assert {row['dedupe'] for row in paged if row['type'] == 'usage'} == {row['dedupe'] for row in legacy_expected}
    with sqlite3.connect(database) as connection:
        connection.execute("DELETE FROM message WHERE session_id='ses_a_origin'")
    copied_only = invoke('--batch', [{'path': str(database), 'resume': None}])
    copy = next(row for row in copied_only if row.get('dedupe') == legacy_expected[0]['dedupe'])
    assert copy['session_id'] == 'ses_z_fork' and copy['tokens'] == legacy_expected[0]['tokens']
    assert copy['at'] == legacy_expected[0]['at']
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE session_message (id TEXT,session_id TEXT,type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT)')
    experimental = invoke('--batch', [{'path': str(database), 'resume': None}])
    assert {row['dedupe'] for row in experimental if row['type'] == 'usage'} == {row['dedupe'] for row in legacy_expected}
print('[PASS] v1 fork copies fold by original millisecond time/model/tokens; parallel token vectors remain distinct')

with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / 'opencode-legacy-updated.db'
    subprocess.run([sys.executable, str(fixtures / 'build_legacy_fixture.py'), str(database)], check=True)
    first = invoke('--batch', [{'path': str(database), 'resume': None}])
    assert not any(row.get('session_id') == 'ses_streaming' for row in first)
    with sqlite3.connect(database) as connection:
        row = connection.execute("SELECT data FROM message WHERE id='msg_legacy_incomplete'").fetchone()
        data = json.loads(row[0])
        data['time']['completed'] = 1794000022137
        data['tokens']['output'] = 9
        connection.execute(
            "UPDATE message SET data=?,time_updated=? WHERE id='msg_legacy_incomplete'",
            (json.dumps(data), 1794000022137),
        )
    resumed = invoke('--batch', [{'path': str(database), 'resume': first[-1]['resume']}])
    completed = [row for row in resumed if row.get('session_id') == 'ses_streaming']
    assert len(completed) == 1 and completed[0]['tokens']['output'] == 10
    assert completed[0]['dedupe'] == 'opencode1:1794000007131:gpt-5:30:10:0:0:1'
    assert resumed[-1]['resume'] == 'r:1794000022137'
print('[PASS] v1 partial assistant usage waits for completion, then resumes to the final token vector')

with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / 'opencode-legacy-malformed.db'
    subprocess.run([sys.executable, str(fixtures / 'build_legacy_fixture.py'), str(database)], check=True)
    with sqlite3.connect(database) as connection:
        row = connection.execute("SELECT data FROM message WHERE id='msg_legacy_original'").fetchone()
        data = json.loads(row[0])
        data['time']['created'] = 1794000001123.5
        connection.execute("UPDATE message SET data=? WHERE id='msg_legacy_original'", (json.dumps(data),))
    invalid = invoke('--batch', [{'path': str(database), 'resume': None}])
    assert invalid[-1]['malformed'] == 1
    assert not any(row.get('session_id') == 'ses_a_origin' for row in invalid)
print('[PASS] v1 identity rejects fractional timestamps rather than rounding away precision')

with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / 'opencode-both-ledgers.db'
    build(database)
    with sqlite3.connect(database) as connection:
        connection.executescript((fixtures / 'legacy_fixture.sql').read_text())
    mixed = invoke('--batch', [{'path': str(database), 'resume': None}], extra_args=('--page-size', '64'))
    assert [row for row in mixed if row['type'] == 'usage'] == expected
print('[PASS] a verified v2 ledger takes precedence over retained legacy messages')

with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / 'opencode-legacy-batch.db'
    subprocess.run([sys.executable, str(fixtures / 'build_legacy_fixture.py'), str(database)], check=True)
    requests = [{'path': str(database), 'resume': None}] * 200
    started = time.perf_counter()
    batch = invoke('--batch', requests)
    elapsed = time.perf_counter() - started
    assert len([row for row in batch if row['type'] == 'checkpoint']) == 200
    assert elapsed / 200 <= 0.05, f'{elapsed * 1000 / 200:.3f} ms/file'
    print(f'[PASS] one 200-file legacy batch: {elapsed * 1000 / 200:.3f} ms/file')

with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / 'batch.db'
    build(database)
    requests = [{'path': str(database), 'resume': None}] * 200
    started = time.perf_counter()
    batch = invoke('--batch', requests)
    elapsed = time.perf_counter() - started
    assert len([row for row in batch if row['type'] == 'checkpoint']) == 200
    assert elapsed / 200 <= 0.05, f'{elapsed * 1000 / 200:.3f} ms/file'
    print(f'[PASS] one 200-file batch: {elapsed * 1000 / 200:.3f} ms/file')
primary_temporary.cleanup()
PY

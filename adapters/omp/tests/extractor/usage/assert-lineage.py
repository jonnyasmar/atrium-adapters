import json
import os
import subprocess
import sys
from pathlib import Path

adapter = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(adapter.parent / 'shared'))
fixture = adapter / 'tests/extractor/usage'
requests = [json.loads(line) for line in (fixture / 'requests.jsonl').read_text().splitlines()]
for request in requests:
    request['path'] = str(fixture / request['path'])
by_session = {
    Path(request['path']).stem.rsplit('_', 1)[-1]: request
    for request in requests
}


def batch(items):
    result = subprocess.run(
        ['bash', str(adapter / 'extract_session.sh'), '--usage', '--batch'],
        input=''.join(json.dumps(row) + '\n' for row in items),
        text=True,
        capture_output=True,
        check=True,
        env=dict(os.environ, ATRIUM_TEST_TRANSCRIPT_ROOT=str(fixture / 'input')),
    )
    return [json.loads(line) for line in result.stdout.splitlines()]


def usage(rows):
    return [row for row in rows if row['type'] == 'usage']


prefix = adapter.name
origin = by_session[f'{prefix}-synthetic']
fork = by_session[f'{prefix}-fork-synthetic']
sibling = by_session[f'{prefix}-sibling-synthetic']
unrelated = by_session[f'{prefix}-unrelated-synthetic']
parent_ref = f'/synthetic/pi/{Path(origin["path"]).name}' if prefix == 'pi' else f'{prefix}-synthetic'

orphaned = usage(batch([fork]))
inherited = [row for row in orphaned if row['fork_of']]
assert len(inherited) == 1
assert inherited[0]['fork_of'] == parent_ref
assert inherited[0]['dedupe'] == 'a1b2c3d4:2026-11-07T00:00:01.000Z'
assert all(row['fork_of'] is None for row in orphaned if row not in inherited)

all_usage = usage(batch([origin, fork, sibling, unrelated]))
merged = {}
from extract_session_usage import fold

for event in all_usage:
    merged[event['dedupe']] = fold(merged.get(event['dedupe']), event)
shared_id = f'a1b2c3d4:2026-11-07T00:00:01.000Z'
shared_request = merged[shared_id]
assert shared_request['session_id'] == f'{prefix}-synthetic'
assert shared_request['fork_of'] is None
assert f'a1b2c3d4:2026-11-07T00:00:10.000Z' in merged
assert f'c3d4e5f6:2026-11-07T00:00:06.000Z' in merged
assert f'e5f6a7b8:2026-11-07T00:00:08.000Z' in merged

siblings = usage(batch([fork, sibling]))
for events in (siblings, list(reversed(siblings))):
    merged_siblings = {}
    for event in events:
        merged_siblings[event['dedupe']] = fold(merged_siblings.get(event['dedupe']), event)
    inherited_sibling = merged_siblings[shared_id]
    assert inherited_sibling['session_id'] == f'{prefix}-fork-synthetic'
    assert inherited_sibling['fork_of'] == parent_ref
    assert f'c3d4e5f6:2026-11-07T00:00:06.000Z' in merged_siblings
    assert f'e5f6a7b8:2026-11-07T00:00:08.000Z' in merged_siblings
print(f'{adapter.name}: inherited fork identity, missing origin, sibling winner, timestamp collision')

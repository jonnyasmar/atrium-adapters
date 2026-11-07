import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from extract_session_usage import fold


def verify(adapter):
    fixture = adapter / 'tests/extractor/usage'
    requests = [json.loads(line) for line in (fixture / 'requests.jsonl').read_text().splitlines()]
    for request in requests:
        request['path'] = str(fixture / request['path'])
    command = ['bash', str(adapter / 'extract_session.sh'), '--usage', '--batch']

    def batch(items, **kwargs):
        result = subprocess.run(command, input=''.join(json.dumps(r) + '\n' for r in items),
                                text=True, capture_output=True, check=True,
                                env=dict(os.environ, ATRIUM_TEST_TRANSCRIPT_ROOT=str(fixture / 'input')), **kwargs)
        return [json.loads(line) for line in result.stdout.splitlines()]

    actual = batch(requests)
    usage = lambda rows: [r for r in rows if r['type'] == 'usage']
    expected = [json.loads(line) for line in (fixture / 'expected-usage.jsonl').read_text().splitlines()]
    assert usage(actual) == expected, (usage(actual), expected)
    totals_file = fixture / 'expected-totals.json'
    if totals_file.exists():
        merged = {}
        for event in usage(actual):
            merged[event['dedupe']] = fold(merged.get(event['dedupe']), event)
        totals = {}
        for event in merged.values():
            record = totals.setdefault(event['session_id'], dict(requests=0, tokens=0))
            record['requests'] += 1
            record['tokens'] += sum(v for k, v in event['tokens'].items() if k != 'reasoning')
        assert totals == json.loads(totals_file.read_text())
    assert len([r for r in actual if r['type'] == 'checkpoint']) == len(requests)
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        for request in requests:
            source = Path(request['path'])
            data = source.read_bytes()
            # Preserve subagent layout and fixture basename in the copy.
            target = temp / source.relative_to(fixture / 'input')
            target.parent.mkdir(parents=True, exist_ok=True)
            copied = dict(request, path=str(target))
            baseline = usage(batch([request]))
            boundaries = [0] + [i + 1 for i, b in enumerate(data) if b == 10]
            for boundary in boundaries:
                target.write_bytes(data[:boundary])
                before = batch([copied])
                token = before[-1]['resume']
                target.write_bytes(data)
                after = batch([dict(copied, resume=token)])
                merged = {}
                for event in usage(before + after):
                    merged[event['dedupe']] = fold(merged.get(event['dedupe']), event)
                assert list(merged.values()) == baseline, (source.name, boundary)
            target.write_bytes(data + b'{"torn":')
            torn = batch([copied])
            assert usage(torn) == baseline
            assert int(torn[-1]['resume'].split(':')[1]) == len(data)
            reset = batch([dict(copied, resume='o:999999:deadbeef')])
            assert reset[-1]['reset'] is True
            corrupt = batch([dict(copied, resume=f'o:{len(data)}:deadbeef')])
            assert corrupt[-1]['reset'] is True
            assert usage(corrupt) == baseline
        errors = batch([dict(path=str(temp / 'missing')), requests[0]])
        assert errors[0]['complete'] is False and errors[-1]['complete'] is True
        env = dict(os.environ, ATRIUM_TEST_TRANSCRIPT_ROOT=str(fixture / 'input'))
        listing = subprocess.run(['bash', str(adapter / 'extract_session.sh'), '--usage', '--list'],
                                 env=env, capture_output=True, text=True, check=True)
        assert len(listing.stdout.splitlines()) == len(requests)
        copies = []
        for index in range(200):
            target = temp / f'budget-{index}.jsonl'
            target.write_bytes(Path(requests[0]['path']).read_bytes())
            copies.append(dict(requests[0], path=str(target)))
        start = time.monotonic()
        rows = batch(copies)
        ms = (time.monotonic() - start) * 1000 / 200
        assert len([r for r in rows if r['type'] == 'checkpoint']) == 200
        assert ms <= 50, ms
        print(f'{adapter.name}: golden, every-boundary resume, torn line, reset, IO isolation; 200 files {ms:.3f} ms/file')


if __name__ == '__main__':
    verify(Path(sys.argv[1]).resolve())

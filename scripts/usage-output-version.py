#!/usr/bin/env python3
import argparse
import ast
from contextlib import closing
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile

MAX_RECONCILABLE_OUTPUT_VERSION = 1
GOLDEN = 'tests/extractor/usage/semantic-output.json'
ROOT_ENV = ('CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'PI_CODING_AGENT_SESSION_DIR',
            'OMP_CODING_AGENT_SESSION_DIR', 'GOOSE_PATH_ROOT', 'GROK_HOME',
            'XDG_DATA_HOME', 'OPENCODE_DB', 'ATRIUM_USAGE_ROOTS')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def output_version(adapter):
    module = ast.parse((adapter / 'extract_session_usage.py').read_text())
    values = [node.value.value for node in module.body
              if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant)
              and any(isinstance(target, ast.Name) and target.id == 'USAGE_OUTPUT_VERSION'
                      for target in node.targets)]
    if len(values) != 1 or type(values[0]) is not int or values[0] < 1:
        raise ValueError('declare one positive integer USAGE_OUTPUT_VERSION in extract_session_usage.py')
    return values[0]


def corpus(adapter, destination):
    fixtures = adapter / 'tests/extractor/usage'
    shutil.copytree(fixtures, destination)
    paths = []
    for path in sorted(destination.rglob('*')):
        if 'expected' in path.stem or path.name == 'requests.jsonl':
            continue
        if path.suffix == '.jsonl':
            paths.append(path)
        elif path.suffix == '.sql':
            database = path.with_suffix('.db')
            with closing(sqlite3.connect(database)) as connection:
                connection.executescript(path.read_text())
            paths.append(database)
    if not paths:
        raise ValueError('semantic output requires invented native fixtures')
    return [{'path': str(path), 'session_id': 'semantic:' + path.relative_to(destination).as_posix(),
             'resume': None} for path in sorted(paths)]


def normalize(row):
    tokens = row.get('tokens', {})
    value = {key: row[key] for key in ['at', 'session_id', 'model', 'dedupe']}
    value.update(type='usage', tokens={key: tokens.get(key, 0) for key in
                 ['input', 'output', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'reasoning']},
                 tier=row.get('tier'), cost_usd=row.get('cost_usd'),
                 subagent=row.get('subagent', False), agent_id=row.get('agent_id'), fork_of=row.get('fork_of'))
    return value


def emitted(adapter, requests, data_root):
    env = dict(os.environ)
    for name in ROOT_ENV:
        env.pop(name, None)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    env['PYTHONPYCACHEPREFIX'] = str(data_root.parent / 'isolated-bytecode')
    env['ATRIUM_TEST_TRANSCRIPT_ROOT'] = str(data_root)
    env['ATRIUM_DATA_DIR'] = str(data_root.parent / 'isolated-home')
    result = subprocess.run([str(adapter / 'extract_session.sh'), '--usage', '--batch'],
                            input=''.join(canonical(request) + '\n' for request in requests),
                            text=True, capture_output=True, env=env, timeout=60)
    if result.returncode:
        raise ValueError('extractor did not read the semantic corpus successfully')
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    checkpoints = [row for row in rows if row.get('type') == 'checkpoint']
    if len(checkpoints) != len(requests) or any(row.get('error') or not row.get('complete')
                                              for row in checkpoints):
        raise ValueError('extractor did not complete every semantic fixture')
    records = [normalize(row) for row in rows if row.get('type') == 'usage']
    records.sort(key=lambda row: (row['dedupe'], canonical(row)))
    return records


def fingerprint(records):
    return hashlib.sha256(canonical(records).encode()).hexdigest()


def transition(version, records, previous_version, previous_records):
    differs = previous_records is None or fingerprint(records) != fingerprint(previous_records)
    if version == previous_version and differs:
        raise ValueError('fixture output changed: bump USAGE_OUTPUT_VERSION')
    if version != previous_version and not differs:
        raise ValueError('a bump must change fixture output; extend the fixture to cover the new semantics')


def git(root, *args, optional=False):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True, check=False, env=env)
    if result.returncode:
        if optional:
            return None
        raise ValueError('cannot read semantic-version history; fetch complete Git history')
    return result.stdout


def previous(root, relative, recorded):
    path = (relative / GOLDEN).as_posix()
    head = git(root, 'show', 'HEAD:' + path, optional=True)
    if head is None:
        return []
    changed = git(root, 'log', '-1', '--format=%H', 'HEAD', '--', path).decode().strip()
    if json.loads(head) != recorded:
        revisions = [changed, 'HEAD']
    else:
        previous_change = git(root, 'log', '-1', '--format=%H', changed + '^', '--', path, optional=True)
        revisions = [changed + '^']
        if previous_change and previous_change.strip():
            revisions.append(previous_change.decode().strip())
    baselines = []
    for revision in dict.fromkeys(revisions):
        data = git(root, 'show', revision + ':' + path, optional=True)
        if data is not None:
            baselines.append((revision, json.loads(data)['version']))
    return baselines


def archived(root, relative, revision, destination):
    relative = relative.as_posix()
    data = git(root, 'archive', '--format=tar', revision, '--', relative, 'adapters/shared')
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination.resolve()) or member.issym() or member.islnk():
                raise ValueError('unsafe path in previous extractor archive')
        archive.extractall(destination)
    return destination / relative


def check(adapter, record=False, repository=None):
    adapter = adapter.resolve()
    root = adapter.parent.parent
    repository = Path(repository).resolve() if repository else root
    relative = adapter.relative_to(root)
    version = output_version(adapter)
    if version > MAX_RECONCILABLE_OUTPUT_VERSION:
        raise ValueError('versions above 1 need app-side reconciliation (not yet supported)')
    path = adapter / GOLDEN
    with tempfile.TemporaryDirectory(prefix='atrium-usage-semantic-') as temporary:
        temporary = Path(temporary)
        requests = corpus(adapter, temporary / 'corpus')
        records = emitted(adapter, requests, temporary / 'corpus')
        current = {'version': version, 'sha256': fingerprint(records), 'records': records}
        if record:
            path.write_text(json.dumps(current, indent=2, ensure_ascii=False, allow_nan=False) + '\n')
        if not path.exists():
            raise ValueError('missing semantic golden; run scripts/usage-output-version.py record ' + adapter.name)
        recorded = json.loads(path.read_text())
        if recorded != current:
            if recorded.get('version') == version:
                raise ValueError('fixture output changed: bump USAGE_OUTPUT_VERSION, then re-record its golden')
            raise ValueError('version and output golden differ; re-record them with scripts/usage-output-version.py record')
        for index, (revision, old_version) in enumerate(previous(repository, relative, recorded)):
            old_adapter = archived(repository, relative, revision, temporary / f'previous-{index}')
            try:
                old_records = emitted(old_adapter, requests, temporary / 'corpus')
            except (OSError, ValueError, subprocess.TimeoutExpired, json.JSONDecodeError):
                old_records = None
            transition(version, records, old_version, old_records)
    return len(records)


def adapters(root, names):
    if names:
        return [Path(name).resolve() if Path(name).is_dir() else root / 'adapters' / name for name in names]
    return [path.parent for path in sorted((root / 'adapters').glob('*/adapter.json'))
            if json.loads(path.read_text()).get('sessionExtractor', {}).get('usage', {}).get('source') == 'transcript']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'record'])
    parser.add_argument('adapters', nargs='*')
    parser.add_argument('--repository', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    for adapter in adapters(root, args.adapters):
        try:
            count = check(adapter, record=args.action == 'record', repository=args.repository)
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            parser.exit(1, f'{adapter.name}: {error}\n')
        print(f'{adapter.name}: semantic output version verified ({count} invented usage records)')


if __name__ == '__main__':
    main()

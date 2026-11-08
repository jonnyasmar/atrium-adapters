"""Benchmark old/new entrypoints on filename-only copies of local session trees.

The real provider trees are only read. Copies preserve directory/file names;
transcripts are empty except for one invented target record. Cache and SQLite
registry writes are confined to the temporary HOME. No provider process runs.
"""
from contextlib import closing
import argparse
import io
import json
import os
from pathlib import Path
import resource
import shutil
import sqlite3
import statistics
import subprocess
import tarfile
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
NAMES = ('pi', 'omp', 'antigravity', 'codex', 'opencode')
ROOTS = {
    'pi': ('.pi/agent/sessions',),
    'omp': ('.omp/agent/sessions',),
    'antigravity': ('.gemini/antigravity-cli', '.antigravity', 'Library/Application Support/Antigravity'),
    'codex': ('.codex/sessions',),
    'opencode': ('.local/share/opencode/project', '.local/share/opencode/storage'),
}


def snapshot(source, target):
    count = 0
    directories = 0
    for current, children, files in os.walk(source, followlinks=False):
        children[:] = [name for name in children if not (Path(current) / name).is_symlink()]
        destination = target / Path(current).relative_to(source)
        destination.mkdir(parents=True, exist_ok=True)
        directories += 1
        for name in files:
            path = Path(current) / name
            if path.is_symlink() or not path.is_file():
                continue
            (destination / name).touch()
            count += 1
    return directories, count


def target_for(name, real_home):
    if name in ('pi', 'omp'):
        for project in (real_home / ROOTS[name][0]).iterdir():
            if not project.is_dir():
                continue
            for path in project.glob('*.jsonl'):
                with path.open() as stream:
                    for _ in range(6):
                        line = stream.readline(65536)
                        try:
                            cwd = json.loads(line).get('cwd')
                        except (ValueError, AttributeError):
                            continue
                        if cwd:
                            return path, path.stem.rsplit('_', 1)[-1], cwd
    elif name == 'antigravity':
        path = next((real_home / ROOTS[name][0] / 'brain').glob('*/.system_generated/logs/transcript.jsonl'), None)
        if path:
            return path, path.parents[2].name, '/benchmark'
    elif name == 'codex':
        path = next((real_home / ROOTS[name][0]).glob('*/*/*/rollout-*.jsonl'), None)
        if path:
            return path, path.stem[-36:], '/benchmark'
    else:
        path = next((real_home / '.local/share/opencode/storage/session_diff').glob('*.json'), None)
        if path:
            return path, path.stem, '/benchmark'
    return None


def measure(script, env, sid, cwd, runs, missing=False, cold=False):
    elapsed, blocks, cpu = [], [], []
    for _ in range(runs):
        if cold and Path(env['ATRIUM_DATA_DIR']).exists():
            shutil.rmtree(env['ATRIUM_DATA_DIR'])
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.perf_counter()
        result = subprocess.run([str(script), '--session-id', sid, '--cwd', cwd, '--depth', 'quick'],
                                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elapsed.append((time.perf_counter() - started) * 1000)
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        blocks.append(after.ru_inblock - before.ru_inblock)
        cpu.append((after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime) * 1000)
        if result.returncode != (1 if missing else 0):
            raise RuntimeError(result.stderr.decode())
    return {'median_ms': round(statistics.median(elapsed), 2), 'max_ms': round(max(elapsed), 2),
            'median_cpu_ms': round(statistics.median(cpu), 2), 'block_inputs': sum(blocks)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', default='1fffc814')
    parser.add_argument('--runs', type=int, default=5)
    args = parser.parse_args()
    real_home = Path.home()
    with tempfile.TemporaryDirectory(prefix='atrium-session-benchmark-') as temporary:
        temporary = Path(temporary)
        archive = subprocess.check_output(['git', 'archive', args.before, 'adapters'], cwd=REPO)
        with tarfile.open(fileobj=io.BytesIO(archive)) as packed:
            packed.extractall(temporary / 'before', filter='data')
        for name in NAMES:
            selected = target_for(name, real_home) if any((real_home / root).is_dir() for root in ROOTS[name]) else None
            if selected is None:
                print(json.dumps({'adapter': name, 'available': False}), flush=True)
                continue
            source, sid, cwd = selected
            home = temporary / name
            dirs = files = 0
            for relative in ROOTS[name]:
                root = real_home / relative
                if root.is_dir():
                    d, f = snapshot(root, home / relative)
                    dirs += d
                    files += f
            target = home / source.relative_to(real_home)
            if name == 'codex':
                target.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': sid, 'cwd': cwd}}) + '\n')
                # Preserve registry cardinality and indexed lookup shape using
                # filenames only; never copy or open the user's live SQLite DB.
                with closing(sqlite3.connect(home / '.codex/state_5.sqlite')) as connection, connection:
                    connection.execute('create table threads(id text primary key, rollout_path text)')
                    connection.executemany('insert or replace into threads values (?, ?)',
                        ((p.stem[-36:], str(p)) for p in (home / '.codex/sessions').glob('*/*/*/rollout-*.jsonl')))
            else:
                target.write_text('{}\n')
            env = {'HOME': str(home), 'PATH': os.environ['PATH'], 'ATRIUM_DATA_DIR': str(temporary / (name + '-cache')),
                   'PYTHONDONTWRITEBYTECODE': '1'}
            # Home-relative Omp encoding must use the original directory names.
            if name == 'omp' and cwd.startswith(str(real_home) + os.sep):
                cwd = str(home) + cwd[len(str(real_home)):]
            row = {'adapter': name, 'snapshot_directories': dirs, 'snapshot_files': files,
                   'runs': args.runs}
            old = temporary / 'before/adapters' / name / 'extract_session.sh'
            new = REPO / 'adapters' / name / 'extract_session.sh'
            row['old_hit'] = measure(old, env, sid, cwd, args.runs)
            row['new_cold_hit'] = measure(new, env, sid, cwd, args.runs, cold=True)
            row['new_indexed_hit'] = measure(new, env, sid, cwd, args.runs)
            missing = sid[:-1] + ('0' if sid[-1] != '0' else '1') if name == 'codex' else 'missing-session'
            row['old_miss'] = measure(old, env, missing, cwd, args.runs, missing=True)
            row['new_miss'] = measure(new, env, missing, cwd, args.runs, missing=True)
            print(json.dumps(row), flush=True)


if __name__ == '__main__':
    main()

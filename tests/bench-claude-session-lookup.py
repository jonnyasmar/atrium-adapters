"""Read-only lookup benchmark; all cache writes go to a temporary directory.

python3 tests/bench-claude-session-lookup.py --root ~/.claude/projects --cwd /path/to/project
Reports cached-OS timings and block input operations, not cold-disk estimates.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ADAPTER = Path(__file__).resolve().parents[1] / 'adapters/claude-code'
spec = importlib.util.spec_from_file_location('session_path', ADAPTER / 'session_path.py')
lookup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lookup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--cwd', required=True)
    parser.add_argument('--runs', type=int, default=15)
    args = parser.parse_args()
    root = args.root.resolve()
    project = root / lookup.encode_project(args.cwd)
    with os.scandir(project) as entries:
        target = next(Path(e.path) for e in entries if e.name.endswith('.jsonl') and e.is_file())
    with os.scandir(root) as entries:
        project_count = sum(e.is_dir(follow_symlinks=False) for e in entries)
    print(json.dumps({'project_directories': project_count, 'runs': args.runs}))
    with tempfile.TemporaryDirectory(prefix='atrium-lookup-bench-') as temporary:
        env = dict(os.environ, ATRIUM_DATA_DIR=temporary, PYTHONDONTWRITEBYTECODE='1')
        worker = Path(temporary) / 'lookup.py'
        worker.write_text('import sys\nsys.path.insert(0, ' + repr(str(ADAPTER)) + ')\n'
                          'from session_path import find_transcript\n'
                          'result = find_transcript(*sys.argv[1:])\n'
                          'sys.exit(0 if result else 1)\n')
        with patch.dict(os.environ, env):
            entry = lookup._cache_entry(root, target.stem)
            # Count actual directory enumerations separately from timing.
            old = subprocess.run(['find', str(root), '(', '-type', 'd', '-print', ')',
                '-o', '(', '-name', target.name, '-quit', ')'], capture_output=True, check=True)
            old_miss = subprocess.run(['find', str(root), '-type', 'd', '-print'], capture_output=True, check=True)
            rows = []
            scenarios = [
                ('old-find-hit', ['find', str(root), '-name', target.name, '-print', '-quit'], False, len(old.stdout.splitlines())),
                ('direct-cold-index', [sys.executable, str(worker), str(root), target.stem, args.cwd], True, 0),
                ('fallback-cold-index', [sys.executable, str(worker), str(root), target.stem, '/not-the-original-cwd'], True, 1),
                ('fallback-index-hit', [sys.executable, str(worker), str(root), target.stem, '/not-the-original-cwd'], False, 0),
                ('old-find-miss', ['find', str(root), '-name', 'atrium-benchmark-missing.jsonl', '-print', '-quit'], False, len(old_miss.stdout.splitlines())),
                ('new-miss', [sys.executable, str(worker), str(root), 'atrium-benchmark-missing', args.cwd], False, 1),
            ]
            for name, command, cold, directories in scenarios:
                times, blocks, cpu = [], [], []
                for _ in range(args.runs):
                    if cold:
                        entry.unlink(missing_ok=True)
                    before = resource.getrusage(resource.RUSAGE_CHILDREN)
                    start = time.perf_counter()
                    result = subprocess.run(command, env=env, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.PIPE, text=True)
                    elapsed = (time.perf_counter() - start) * 1000
                    if result.returncode not in (0, 1) or (result.returncode == 1 and name != 'new-miss'):
                        raise RuntimeError(result.stderr)
                    times.append(elapsed)
                    after = resource.getrusage(resource.RUSAGE_CHILDREN)
                    blocks.append(after.ru_inblock - before.ru_inblock)
                    cpu.append((after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime) * 1000)
                rows.append(dict(scenario=name, median_ms=round(statistics.median(times), 3),
                                 max_ms=round(max(times), 3), median_cpu_ms=round(statistics.median(cpu), 3),
                                 transcript_directory_reads=directories,
                                 block_input_operations=sum(blocks)))
            fixture = ADAPTER / 'tests/extractor'
            env['ATRIUM_TEST_TRANSCRIPT_ROOT'] = str(fixture)
            fixture_id = (fixture / 'fixture-session-id.txt').read_text().strip()
            times = []
            for _ in range(args.runs):
                start = time.perf_counter()
                subprocess.run([str(ADAPTER / 'extract_session.sh'), '--session-id', fixture_id,
                                '--cwd', args.cwd, '--depth', 'standard'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
                times.append((time.perf_counter() - start) * 1000)
            rows.append(dict(scenario='full-entrypoint-small-fixture',
                             median_ms=round(statistics.median(times), 3), max_ms=round(max(times), 3)))
            print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()

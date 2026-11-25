import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--session-id', required=True)
    parser.add_argument('--cwd', required=True)
    parser.add_argument('--depth', choices=['quick'], default='quick')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,256}', args.session_id):
        return 10
    cwd = args.cwd.replace('\\', '/').rstrip('/')
    slug = re.sub('[^a-z0-9._-]+', '-', cwd.rsplit('/', 1)[-1].lower()).strip('-')[:40].strip('-')
    if slug in ('', '.', '..'):
        slug = 'workspace'
    workspace = f'wd_{slug}_{hashlib.sha256(cwd.encode()).hexdigest()[:12]}'
    root = Path(os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT') or os.environ.get('KIMI_CODE_HOME') or Path.home() / '.kimi-code')
    source = root / 'sessions' / workspace / args.session_id / 'agents/main/wire.jsonl'
    try:
        with source.open() as stream:
            metadata = json.loads(stream.readline())
        started = metadata['created_at']
        if isinstance(started, (float, int)):
            started = datetime.fromtimestamp(started / 1000, timezone.utc).isoformat()
        last = datetime.fromtimestamp(source.stat().st_mtime, timezone.utc).isoformat()
    except FileNotFoundError:
        return 1
    print(json.dumps(dict(type='session_start', session_id=args.session_id, adapter='kimi', cwd=args.cwd, started_at=started)))
    print(json.dumps(dict(type='session_end', session_id=args.session_id, ended_at=last, event_count=2)))
    return 0


if __name__ == '__main__':
    sys.exit(main())

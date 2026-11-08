import os
from pathlib import Path
import sys

adapter = Path(__file__).resolve().parent
shared = adapter.parents[3] / 'shared' if adapter.parent.name == 'generations' and adapter.parents[2].name == '.managed' else adapter.parent / 'shared'
sys.path.insert(0, str(shared))
from session_lookup import PathIndex, component, fixture


def matches_session(base, sid):
    return base == sid or base == 'ses_' + sid or base.endswith('_' + sid)


def legacy_path(root, sid):
    import glob

    for pattern in ('project/*/storage/session/info/*.json',
                    'storage/session_diff/*.json', 'storage/session/info/*.json'):
        for name in glob.glob(str(root / pattern)):
            path = Path(name)
            if matches_session(path.stem, sid) and path.is_file():
                return path
    return None


def find_transcript(sid, cwd=''):
    if not component(sid):
        return None
    testing, path = fixture(sid, '.json')
    if testing:
        return path
    root = Path.home() / '.local/share/opencode'
    index = PathIndex('opencode', [root])
    names = [sid + '.json']
    if not sid.startswith('ses_'):
        names.append('ses_' + sid + '.json')
    cached = index.get(sid)
    if cached and matches_session(cached.stem, sid):
        return cached
    for directory in (root / 'storage/session/info', root / 'storage/session_diff'):
        for name in names:
            path = directory / name
            if path.is_file():
                return index.put(sid, path)
    try:
        with os.scandir(root / 'project') as projects:
            for project in projects:
                if not project.is_dir(follow_symlinks=False):
                    continue
                for name in names:
                    path = Path(project.path) / 'storage/session/info' / name
                    if path.is_file():
                        return index.put(sid, path)
    except OSError:
        pass
    path = legacy_path(root, sid)
    return index.put(sid, path) if path else None


def messages_directory(info):
    if info.name == 'fixture-session.json' and os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT'):
        return info.parent / 'fixture-messages'
    return info.parent.parent / 'messages' / info.stem

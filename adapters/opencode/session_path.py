import os
from pathlib import Path
import sys

adapter = Path(__file__).resolve().parent
shared = adapter.parents[3] / 'shared' if adapter.parent.name == 'generations' and adapter.parents[2].name == '.managed' else adapter.parent / 'shared'
sys.path.insert(0, str(shared))
from session_lookup import PathIndex, component, fixture


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
    if cached and cached.name in names:
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
    except FileNotFoundError:
        pass
    return None


def messages_directory(info):
    if info.name == 'fixture-session.json' and os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT'):
        return info.parent / 'fixture-messages'
    return info.parent.parent / 'messages' / info.stem

import json
import os
from pathlib import Path


def component(value):
    return isinstance(value, str) and bool(value) and value not in ('.', '..') and not any(
        char in value for char in ('/', '\\', '\x00'))


def read_cache(path):
    try:
        with path.open(encoding='utf-8') as stream:
            return json.load(stream)
    except (OSError, ValueError):
        return None


def write_cache(path, value):
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        candidate = path.with_name(path.name + '.' + os.urandom(8).hex())
        descriptor = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        temporary = candidate
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream)
        os.replace(temporary, path)
    except OSError:
        pass
    finally:
        if temporary:
            try:
                temporary.unlink()
            except OSError:
                pass


class PathIndex:
    def __init__(self, adapter, roots):
        self.roots = [Path(os.path.abspath(root)) for root in roots]
        data = Path(os.environ.get('ATRIUM_DATA_DIR') or Path.home() / '.atrium')
        self.directory = data / 'cache/session-paths-v1' / adapter
        self.scope = '\x00'.join(map(str, self.roots))

    def key(self, name):
        import hashlib

        digest = hashlib.sha256((self.scope + '\x00' + name).encode()).hexdigest()
        return self.directory / digest

    def get(self, sid):
        value = read_cache(self.key('session:' + sid))
        if not isinstance(value, str):
            return None
        path = Path(value)
        if not path.is_absolute() or '..' in path.parts:
            return None
        if any(path.is_relative_to(root) for root in self.roots) and path.is_file():
            return path
        return None

    def put(self, sid, path):
        path = Path(os.path.abspath(path))
        if self.get(sid) != path:
            write_cache(self.key('session:' + sid), str(path))
        return path


def fixture(sid, suffix='.jsonl'):
    root = os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT')
    if not root:
        return False, None
    root = Path(root)
    try:
        pinned = ''.join((root / 'fixture-session-id.txt').read_text().split())
        path = root / ('fixture-session' + suffix)
        return True, path if pinned == sid and path.is_file() else None
    except OSError:
        return True, None

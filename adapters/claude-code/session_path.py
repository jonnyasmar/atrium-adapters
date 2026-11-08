import json
import os
from pathlib import Path


def encode_project(cwd):
    # Claude encodes UTF-16 units, including punctuation and surrogate pairs;
    # paths over 200 units carry the absolute signed Java-style hash in base36.
    raw = cwd.encode('utf-16-le', errors='surrogatepass')
    units = [raw[i] | raw[i + 1] << 8 for i in range(0, len(raw), 2)]
    encoded = ''.join(chr(u) if 48 <= u <= 57 or 65 <= u <= 90 or 97 <= u <= 122
                      else '-' for u in units)
    if len(encoded) <= 200:
        return encoded
    hashed = 0
    for unit in units:
        hashed = (hashed * 31 + unit) & 0xffffffff
    hashed = abs(hashed if hashed < 0x80000000 else hashed - 0x100000000)
    suffix = ''
    while hashed:
        hashed, digit = divmod(hashed, 36)
        suffix = '0123456789abcdefghijklmnopqrstuvwxyz'[digit] + suffix
    return encoded[:200] + '-' + (suffix or '0')


def _component(value):
    return isinstance(value, str) and bool(value) and value not in ('.', '..') and not any(
        char in value for char in ('/', '\\', '\x00'))


def _cache_entry(root, session_id):
    import hashlib

    data = Path(os.environ.get('ATRIUM_DATA_DIR') or Path.home() / '.atrium')
    key = hashlib.sha256(os.fsencode(root) + b'\x00' + session_id.encode('utf-8')).hexdigest()
    return data / 'cache/claude-session-paths-v1' / key


def _cached_project(entry):
    try:
        with entry.open(encoding='utf-8') as stream:
            project = json.loads(stream.read(4096))
        return project if _component(project) else None
    except (OSError, ValueError):
        return None


def _remember(entry, project):
    if _cached_project(entry) == project:
        return
    temporary = None
    try:
        entry.parent.mkdir(parents=True, exist_ok=True)
        candidate = entry.with_name(entry.name + '.' + os.urandom(8).hex())
        descriptor = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        temporary = candidate
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(project, stream)
        os.replace(temporary, entry)
    except OSError:
        # The index is disposable: a read-only or full cache must not hide a transcript.
        pass
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def find_transcript(root, session_id, cwd, fixture=False):
    if not _component(session_id):
        return None
    root = Path(os.path.abspath(root))
    if fixture and (root / 'fixture-session.jsonl').is_file() and (root / 'fixture-session-id.txt').is_file():
        pinned = ''.join((root / 'fixture-session-id.txt').read_text().split())
        return root / 'fixture-session.jsonl' if session_id == pinned else None

    filename = session_id + '.jsonl'
    entry = _cache_entry(root, session_id)
    if cwd:
        direct = root / encode_project(cwd) / filename
        if direct.is_file():
            _remember(entry, direct.parent.name)
            return direct
    if (root / filename).is_file():
        return root / filename

    project = _cached_project(entry)
    if project:
        cached = root / project / filename
        if cached.is_file():
            return cached
        try:
            entry.unlink()
        except OSError:
            pass

    # Bootstrap/repair only this session's index entry. Read the project names
    # once and stat exact filenames; never list project contents or subagents.
    # New and moved sessions are visible immediately, without a full index rebuild.
    try:
        with os.scandir(root) as projects:
            for project in projects:
                if not project.is_dir(follow_symlinks=False):
                    continue
                candidate = os.path.join(project.path, filename)
                if os.path.isfile(candidate):
                    _remember(entry, project.name)
                    return Path(candidate)
    except FileNotFoundError:
        return None
    return None

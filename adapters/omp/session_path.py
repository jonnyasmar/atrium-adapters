import os
from pathlib import Path
import re
import sys

adapter = Path(__file__).resolve().parent
shared = adapter.parents[3] / 'shared' if adapter.parent.name == 'generations' and adapter.parents[2].name == '.managed' else adapter.parent / 'shared'
sys.path.insert(0, str(shared))
from session_lookup import timestamp_lookup


def encoded_cwds(cwd):
    import hashlib
    import tempfile

    encode = lambda value: re.sub(r'[/\\:]', '-', value)
    legacy = lambda value: '--' + encode(re.sub(r'^[/\\]', '', value)) + '--'
    canonical = os.path.realpath(cwd)
    scope = 'abs'
    name = legacy(canonical)
    for base, prefix, candidate_scope in ((Path.home(), '-', 'home'), (tempfile.gettempdir(), '-tmp', 'tmp')):
        try:
            relative = Path(canonical).relative_to(os.path.realpath(base))
        except ValueError:
            continue
        encoded = encode(str(relative)) if str(relative) != '.' else ''
        name = prefix + (('' if prefix.endswith('-') else '-') + encoded if encoded else '')
        scope = candidate_scope
        break
    readable = re.sub(r'[^a-zA-Z0-9._-]+', '-', os.path.basename(canonical)).strip('-')[-80:] or 'project'
    hashed = scope + '-' + readable + '-' + hashlib.sha256(canonical.replace('\\', '/').encode()).hexdigest()
    # Omp's session-paths.ts migrates both absolute and 17.2.5–17.2.8 hashed
    # spellings. Probe them read-only; atrium must never perform that migration.
    return list(dict.fromkeys((name, legacy(cwd), legacy(canonical), hashed)))


def find_transcript(sid, cwd):
    override = os.environ.get('OMP_CODING_AGENT_SESSION_DIR') or os.environ.get('PI_CODING_AGENT_SESSION_DIR')
    root = Path(override or Path.home() / '.omp/agent/sessions')
    def directories():
        if cwd:
            for name in encoded_cwds(cwd):
                yield root / name
        if override:
            yield root
    return timestamp_lookup('omp', root, sid, directories)

from pathlib import Path
import sys

adapter = Path(__file__).resolve().parent
shared = adapter.parents[3] / 'shared' if adapter.parent.name == 'generations' and adapter.parents[2].name == '.managed' else adapter.parent / 'shared'
sys.path.insert(0, str(shared))
from session_lookup import component, fixture


def find_transcript(sid, cwd=''):
    if not component(sid):
        return None
    testing, path = fixture(sid)
    if testing:
        return path
    home = Path.home()
    for root in (home / '.gemini/antigravity-cli', home / '.antigravity',
                 home / 'Library/Application Support/Antigravity'):
        path = root / 'brain' / sid / '.system_generated/logs/transcript.jsonl'
        if path.is_file():
            return path
    return None

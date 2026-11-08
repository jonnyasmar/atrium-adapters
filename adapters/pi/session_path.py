import os
from pathlib import Path
import re
import sys

adapter = Path(__file__).resolve().parent
shared = adapter.parents[3] / 'shared' if adapter.parent.name == 'generations' and adapter.parents[2].name == '.managed' else adapter.parent / 'shared'
sys.path.insert(0, str(shared))
from session_lookup import timestamp_lookup


def encoded_cwd(cwd):
    return '--' + re.sub(r'[/\\:]', '-', re.sub(r'^[/\\]', '', cwd)) + '--'


def find_transcript(sid, cwd):
    root = Path(os.environ.get('PI_CODING_AGENT_SESSION_DIR') or Path.home() / '.pi/agent/sessions')
    directories = [root / encoded_cwd(cwd)] if cwd else []
    if os.environ.get('PI_CODING_AGENT_SESSION_DIR'):
        directories.append(root)
    return timestamp_lookup('pi', root, sid, directories)

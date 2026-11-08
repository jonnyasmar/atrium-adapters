import os
import sys
from pathlib import Path


def shared_dir():
    # <data>/adapters/<name> links to .managed/<name>/generations/<id>, whose
    # resolved parent is not the adapters dir: try the logical path first.
    for adapter in (Path(os.path.abspath(__file__)).parent, Path(__file__).resolve().parent):
        parts = adapter.parts
        managed = len(parts) > 4 and parts[-4] == '.managed' and parts[-2] == 'generations'
        shared = (Path(*parts[:-4]) if managed else adapter.parent) / 'shared'
        if shared.is_dir():
            return str(shared)
    sys.exit(f'extract_session: no shared/ runtime found from {__file__}')


sys.path.insert(0, shared_dir())
from extract_session_usage import main


def session_id(path):
    return Path(path).parent.name


class CopilotUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)

    def event(self, row):
        # Copilot's per-call assistant.usage stream event is ephemeral and is
        # not present in persisted session-state event logs.
        return None


def defaults():
    homes = [Path.home() / '.copilot']
    if os.environ.get('COPILOT_HOME'):
        homes.append(Path(os.environ['COPILOT_HOME']).expanduser())
    return [str(home / 'session-state') for home in homes]


if __name__ == '__main__':
    sys.exit(main(CopilotUsage, defaults(), session_id))

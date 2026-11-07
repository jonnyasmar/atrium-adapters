import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
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

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from extract_session_usage import main


def session_id(path):
    return Path(path).parent.parent.parent.name


class AntigravityUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)

    def event(self, row):
        # Official per-step usage is documented for the live stream-json
        # output, but not as persisted transcript data.
        return None


def defaults():
    homes = [Path.home() / '.gemini' / 'antigravity-cli' / 'brain']
    if os.environ.get('ANTIGRAVITY_HOME'):
        homes.append(Path(os.environ['ANTIGRAVITY_HOME']).expanduser())
    return [str(home) for home in homes]


if __name__ == '__main__':
    sys.exit(main(AntigravityUsage, defaults(), session_id))

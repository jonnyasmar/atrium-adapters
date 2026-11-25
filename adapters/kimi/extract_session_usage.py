import os
import sys
from datetime import datetime, timezone
from pathlib import Path

USAGE_OUTPUT_VERSION = 1


def shared_dir():
    for adapter in (Path(os.path.abspath(__file__)).parent, Path(__file__).resolve().parent):
        parts = adapter.parts
        managed = len(parts) > 4 and parts[-4] == '.managed' and parts[-2] == 'generations'
        shared = (Path(*parts[:-4]) if managed else adapter.parent) / 'shared'
        if shared.is_dir():
            return str(shared)
    raise ValueError('shared runtime unavailable')


sys.path.insert(0, shared_dir())
from extract_session_usage import main, count


def session_id(path):
    return path.parents[2].name


class KimiUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)
        self.agent = path.parent.name

    def event(self, row):
        # context.append_loop_event repeats the same counters. Context-size
        # token_counting records are occupancy, not additional requests.
        if row.get('type') != 'usage.record':
            return None
        usage = row['usage']
        at = datetime.fromtimestamp(row['time'] / 1000, timezone.utc)
        return dict(type='usage', at=at.isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
                    session_id=self.session, model=row.get('model') or '__none',
                    dedupe=f'kimi:{self.session}:{self.agent}:{self.offset}',
                    subagent=self.agent != 'main', agent_id=self.agent if self.agent != 'main' else None,
                    tokens=dict(input=count(usage.get('inputOther')), output=count(usage.get('output')),
                                cache_read=count(usage.get('inputCacheRead')),
                                cache_write_5m=count(usage.get('inputCacheCreation')), cache_write_1h=0, reasoning=0))


if __name__ == '__main__':
    root = Path(os.environ.get('KIMI_CODE_HOME') or Path.home() / '.kimi-code')
    sys.exit(main(KimiUsage, [str(root / 'sessions')], session_id, lambda name: name == 'wire.jsonl'))

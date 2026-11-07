import os
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from extract_session_usage import count, main


def session_id(path):
    stem = path.name.removesuffix('.zst').removesuffix('.jsonl')
    return stem.rsplit('_', 1)[-1]


def timestamp(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        except (OverflowError, OSError, ValueError):
            return None
    return value if isinstance(value, str) and value else None


class OmpUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)
        self.ordinal = 0

    def usage_record(self, row):
        message = row.get('message')
        if row.get('type') != 'message' or not isinstance(message, dict) or message.get('role') != 'assistant':
            return None
        usage = message.get('usage')
        return (usage, message) if isinstance(usage, dict) else None

    def restore_context(self, stream, offset):
        stream.seek(0)
        remaining = offset
        while remaining > 0:
            line = stream.readline()
            if not line or not line.endswith(b'\n'):
                break
            remaining -= len(line)
            try:
                row = json.loads(line)
            except (ValueError, TypeError):
                continue
            if row.get('type') == 'session' and isinstance(row.get('id'), str) and row['id']:
                self.session = row['id']
            elif self.usage_record(row) is not None:
                self.ordinal += 1

    def event(self, row):
        if row.get('type') == 'session' and isinstance(row.get('id'), str) and row['id']:
            self.session = row['id']
            return None
        record = self.usage_record(row)
        if record is None:
            return None
        usage, message = record

        self.ordinal += 1
        output = count(usage.get('output'))
        entry_id = row.get('id')
        dedupe_id = entry_id if isinstance(entry_id, str) and entry_id else str(self.ordinal)
        at = timestamp(row.get('timestamp'))
        if not at:
            return None
        return dict(
            type='usage', at=at, session_id=self.session,
            model=message.get('model') if isinstance(message.get('model'), str) and message.get('model') else '__none',
            dedupe=f'{self.session}:{dedupe_id}',
            tokens=dict(input=count(usage.get('input')), output=output,
                        cache_read=count(usage.get('cacheRead')),
                        cache_write_5m=count(usage.get('cacheWrite')),
                        cache_write_1h=0,
                        reasoning=min(output, count(usage.get('reasoningTokens')))),
            tier=None, cost_usd=None, subagent=False, agent_id=None, fork_of=None)


if __name__ == '__main__':
    roots = [Path.home() / '.omp/agent/sessions']
    if os.environ.get('OMP_CODING_AGENT_SESSION_DIR'):
        roots.insert(0, Path(os.environ['OMP_CODING_AGENT_SESSION_DIR']))
    if os.environ.get('PI_CODING_AGENT_SESSION_DIR'):
        roots.insert(0, Path(os.environ['PI_CODING_AGENT_SESSION_DIR']))
    sys.exit(main(OmpUsage, [str(root) for root in roots], session_id))

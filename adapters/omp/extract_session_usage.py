import os
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

USAGE_OUTPUT_VERSION = 1


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
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    except ValueError:
        return None


class OmpUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)
        self.ordinal = 0
        self.parent_session = None
        self.session_timestamp = None

    def header(self, row):
        if isinstance(row.get('id'), str) and row['id']:
            self.session = row['id']
        self.parent_session = row.get('parentSession') if isinstance(row.get('parentSession'), str) and row.get('parentSession') else None
        self.session_timestamp = timestamp(row.get('timestamp'))

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
            if row.get('type') == 'session':
                self.header(row)
            elif self.usage_record(row) is not None:
                self.ordinal += 1

    def event(self, row):
        if row.get('type') == 'session':
            self.header(row)
            return None
        record = self.usage_record(row)
        if record is None:
            return None
        usage, message = record

        self.ordinal += 1
        output = count(usage.get('output'))
        entry_id = row.get('id')
        at = timestamp(row.get('timestamp'))
        if not at:
            return None
        dedupe = f'{entry_id}:{at}' if isinstance(entry_id, str) and entry_id else f'{self.session}:{self.ordinal}'
        return dict(
            type='usage', at=at, session_id=self.session,
            model=message.get('model') if isinstance(message.get('model'), str) and message.get('model') else '__none',
            dedupe=dedupe,
            tokens=dict(input=count(usage.get('input')), output=output,
                        cache_read=count(usage.get('cacheRead')),
                        cache_write_5m=count(usage.get('cacheWrite')),
                        cache_write_1h=0,
                        reasoning=min(output, count(usage.get('reasoningTokens')))),
            tier=None, cost_usd=None, subagent=False, agent_id=None,
            fork_of=self.parent_session if self.parent_session and self.session_timestamp and at < self.session_timestamp else None)


if __name__ == '__main__':
    roots = [Path.home() / '.omp/agent/sessions']
    if os.environ.get('OMP_CODING_AGENT_SESSION_DIR'):
        roots.insert(0, Path(os.environ['OMP_CODING_AGENT_SESSION_DIR']))
    if os.environ.get('PI_CODING_AGENT_SESSION_DIR'):
        roots.insert(0, Path(os.environ['PI_CODING_AGENT_SESSION_DIR']))
    sys.exit(main(OmpUsage, [str(root) for root in roots], session_id))

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from extract_session_usage import count, main


def session_id(path):
    return Path(path).parent.name


class GrokUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)
        self.ordinal = 0

    @staticmethod
    def usage_record(row):
        if row.get('method') != '_x.ai/session/update':
            return None
        params = row.get('params') or {}
        update = params.get('update') or {}
        if update.get('sessionUpdate') != 'response_completed':
            return None
        usage = update.get('usage')
        return (params, update, usage) if isinstance(usage, dict) else None

    def restore_context(self, stream, offset):
        stream.seek(0)
        while stream.tell() < offset:
            line = stream.readline()
            if not line or not line.endswith(b'\n'):
                break
            try:
                row = json.loads(line)
                if self.usage_record(row):
                    self.ordinal += 1
            except (ValueError, TypeError, AttributeError):
                continue

    def event(self, row):
        record = self.usage_record(row)
        if not record:
            return None
        params, update, usage = record
        self.ordinal += 1
        at = row.get('timestamp')
        if not isinstance(at, int) or isinstance(at, bool) or at < 0 or at > 253402300799:
            return None
        candidate_session = params.get('sessionId')
        session = candidate_session if isinstance(candidate_session, str) and candidate_session else self.session
        message_id = update.get('message_id')
        meta = params.get('_meta') or {}
        event_id = meta.get('eventId') if isinstance(meta, dict) else None
        dedupe = next((identity for identity in (message_id, event_id)
                       if isinstance(identity, str) and identity), f'{session}:{self.ordinal}')
        output = count(usage.get('output_tokens'))
        return dict(
            type='usage',
            at=datetime.fromtimestamp(at, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
            session_id=session,
            model='__none',
            dedupe=dedupe,
            tokens=dict(
                input=count(usage.get('input_tokens')),
                output=output,
                cache_read=count(usage.get('cache_read_input_tokens')),
                cache_write_5m=count(usage.get('cache_creation_input_tokens')),
                cache_write_1h=0,
                reasoning=min(output, count(usage.get('reasoning_tokens'))),
            ),
            tier=None,
            cost_usd=None,
            subagent=False,
            agent_id=None,
            fork_of=None,
        )


def defaults():
    homes = [Path.home() / '.grok']
    if os.environ.get('GROK_HOME'):
        homes.append(Path(os.environ['GROK_HOME']).expanduser())
    return [str(home / kind) for home in homes for kind in ('sessions', 'archived_sessions')]


if __name__ == '__main__':
    sys.exit(main(GrokUsage, defaults(), session_id, lambda name: name == 'updates.jsonl'))

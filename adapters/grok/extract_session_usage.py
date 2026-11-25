import json
import math
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

USAGE_OUTPUT_VERSION = 2


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
from usage_totals import legacy_events


def session_id(path):
    return Path(path).parent.name


class GrokUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)
        self.ordinal = 0
        self.response_mode = False

    def checkpoint_state(self):
        return dict(ordinal=self.ordinal, response_mode=self.response_mode)

    def restore_state(self, state):
        self.ordinal = count(state.get('ordinal'))
        self.response_mode = bool(state.get('response_mode'))

    @staticmethod
    def notification(row):
        if row.get('method') != '_x.ai/session/update':
            return None
        params = row.get('params') or {}
        update = params.get('update') or {}
        return params, update

    @staticmethod
    def prompt(params, update):
        meta = params.get('_meta') or {}
        prompt = update.get('prompt_id') or (meta.get('promptId') if isinstance(meta, dict) else None)
        return prompt if isinstance(prompt, str) and prompt else None

    def observe(self, row):
        notification = self.notification(row)
        if not notification:
            return False
        params, update = notification
        # Older transcripts have only turn totals. Once the session starts
        # writing responses, its turn totals overlap those per-request records,
        # including delayed and duplicated totals for interleaved prompts.
        if update.get('sessionUpdate') == 'response_completed' and isinstance(update.get('usage'), dict):
            self.response_mode = True
        return self.response_mode

    @staticmethod
    def has_aggregate_usage(usage):
        counters = (
            'modelCalls', 'inputTokens', 'outputTokens', 'totalTokens', 'cachedReadTokens',
            'cacheCreationTokens', 'reasoningTokens', 'costUsdTicks',
            'cacheReadInputTokens', 'cacheCreationInputTokens', 'costUSD',
        )
        models = usage.get('modelUsage')
        entries = [usage, *(models.values() if isinstance(models, dict) else ())]
        return any(
            (isinstance(value, int) and not isinstance(value, bool) and value > 0)
            or (isinstance(value, float) and math.isfinite(value) and value > 0)
            for entry in entries if isinstance(entry, dict)
            for value in (entry.get(key) for key in counters)
        )

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
                self.observe(row)
                if self.usage_record(row):
                    self.ordinal += 1
            except (ValueError, TypeError, AttributeError):
                continue

    def event(self, row):
        covered = self.observe(row)
        record = self.usage_record(row)
        if not record:
            notification = self.notification(row)
            if not notification or covered:
                return None
            params, update = notification
            usage = update.get('usage')
            if update.get('sessionUpdate') != 'turn_completed' or not isinstance(usage, dict) or not self.has_aggregate_usage(usage):
                return None
            at = row.get('timestamp')
            if not isinstance(at, int) or isinstance(at, bool) or not 0 <= at <= 253402300799:
                return None
            session = params.get('sessionId') or self.session
            identity = self.prompt(params, update) or (params.get('_meta') or {}).get('eventId') or str(self.offset)
            stamp = datetime.fromtimestamp(at, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
            return legacy_events(usage, session, identity, stamp)
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

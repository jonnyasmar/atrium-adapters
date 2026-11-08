import json
import math
import os
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
    return Path(path).parent.name


class GrokUsage:
    def __init__(self, path, supplied_id):
        self.session = supplied_id or session_id(path)
        self.ordinal = 0
        self.response_prompts = set()
        self.aggregate_prompts = set()
        self.responses_since_aggregate = False
        self.unassigned_response = False
        self.unidentified_legacy = False

    @staticmethod
    def notification(row):
        if row.get('method') != '_x.ai/session/update':
            return None
        params = row.get('params') or {}
        update = params.get('update') or {}
        return params, update

    def observe(self, row):
        notification = self.notification(row)
        if not notification:
            return
        params, update = notification
        kind = update.get('sessionUpdate')
        if kind not in ('response_completed', 'turn_completed') or not isinstance(update.get('usage'), dict):
            return
        meta = params.get('_meta') or {}
        prompt = update.get('prompt_id') or (meta.get('promptId') if isinstance(meta, dict) else None)
        prompt = prompt if isinstance(prompt, str) and prompt else None
        if kind == 'response_completed':
            self.responses_since_aggregate = True
            if prompt:
                self.response_prompts.add(prompt)
            else:
                self.unassigned_response = True
        else:
            if self.has_aggregate_usage(update['usage']):
                if prompt:
                    self.aggregate_prompts.add(prompt)
                    if self.unassigned_response:
                        self.response_prompts.add(prompt)
                elif not self.responses_since_aggregate:
                    self.unidentified_legacy = True
            self.responses_since_aggregate = False
            self.unassigned_response = False

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

    def checkpoint_unrecorded(self):
        if self.unidentified_legacy or self.aggregate_prompts - self.response_prompts:
            return dict(reason='legacy-turn-totals', count=1)
        return None

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
        self.observe(row)
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

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'shared'))
from extract_session_usage import DeferredUsage, count, main, roots
from usage_stream import open_transcript, transcript_name

METADATA = {}
INDEXED = set()
PATHS = {}
SESSION_PATHS = {}
SEQUENCES = {}
PREFIXES = {}


def header(path):
    try:
        with open_transcript(path) as stream:
            row = json.loads(stream.readline())
        raw = row.get('payload', {}) if row.get('type') == 'session_meta' else {}
        raw = raw if isinstance(raw, dict) else {}
        meta = {key: raw[key] for key in ('id', 'model', 'forked_from_id',
                                        'subagent_history_start_ordinal') if key in raw}
        if parent_thread(raw):
            meta['parent_thread_id'] = parent_thread(raw)
        if meta.get('id'):
            METADATA[meta['id']] = meta
            SESSION_PATHS[meta['id']] = path
        return meta
    except (OSError, ValueError, AttributeError):
        return {}


def session_id(path):
    return header(path).get('id')


def defaults():
    homes = [Path.home() / '.codex']
    if os.environ.get('CODEX_HOME'):
        homes.append(Path(os.environ['CODEX_HOME']))
    data = os.environ.get('ATRIUM_DATA_DIR')
    if data:
        registry = Path(data) / 'codex-account-homes.json'
        try:
            saved = json.loads(registry.read_text())
            for record in saved.get('records', {}).values():
                if isinstance(record.get('path'), str):
                    homes.append(Path(record['path']))
        except (OSError, ValueError, AttributeError):
            pass
    return [str(home / kind) for home in homes for kind in ('sessions', 'archived_sessions')]


def ancestors(path):
    local = next((p for p in path.parents if p.name in ('sessions', 'archived_sessions')), path.parent)
    for root in [local] + roots(defaults()):
        if root in INDEXED:
            continue
        INDEXED.add(root)
        for directory, _, files in os.walk(root, followlinks=False):
            for name in files:
                if transcript_name(name):
                    PATHS[name] = Path(directory) / name


def ancestor_metadata(session):
    if session not in METADATA:
        matching = [path for name, path in PATHS.items()
                    if name.endswith((session + '.jsonl', session + '.jsonl.zst'))]
        # Invented fixture names and nonstandard rollout names may omit the UUID.
        for path in matching or PATHS.values():
            meta = header(path)
            if meta.get('id') == session:
                break
        if session not in METADATA:
            METADATA[session] = None
    return METADATA.get(session)


def parent_thread(meta):
    source = meta.get('source')
    source = source if isinstance(source, dict) else {}
    subagent = source.get('subagent', source.get('subAgent', {}))
    subagent = subagent if isinstance(subagent, dict) else {}
    spawn = subagent.get('thread_spawn', subagent.get('threadSpawn', {}))
    spawn = spawn if isinstance(spawn, dict) else {}
    return (meta.get('parent_thread_id') or meta.get('parentThreadId')
            or spawn.get('parent_thread_id') or spawn.get('parentThreadId'))


def signature(row):
    payload = row.get('payload') or {}
    if row.get('type') != 'event_msg' or payload.get('type') != 'token_count':
        return None
    info = payload.get('info') or {}
    last, total = info.get('last_token_usage'), info.get('total_token_usage')
    if isinstance(last, dict) and last and isinstance(total, dict):
        return total, last
    return None


def sequence(session):
    if session not in SEQUENCES:
        if ancestor_metadata(session) is None or session not in SESSION_PATHS:
            raise DeferredUsage('fork ancestor unavailable')
        values = []
        try:
            with open_transcript(SESSION_PATHS[session]) as stream:
                for line in stream:
                    if not line.endswith(b'\n'):
                        break
                    try:
                        row = json.loads(line)
                        value = signature(row)
                        if value is not None:
                            values.append((value, row.get('ordinal')))
                    except (ValueError, TypeError, AttributeError):
                        continue
        except OSError as error:
            raise DeferredUsage('fork ancestor unavailable') from error
        SEQUENCES[session] = values
    return SEQUENCES[session]


def inherited_prefix(meta):
    session = meta['id']
    if session not in PREFIXES:
        child, parent = sequence(session), sequence(meta['forked_from_id'])
        length = 0
        for own, ancestor in zip(child, parent):
            if own[0] != ancestor[0]:
                break
            length += 1
        PREFIXES[session] = length
    return PREFIXES[session]


class CodexUsage:
    def __init__(self, path, supplied_id):
        self.meta = header(path)
        self.session = self.meta.get('id') or supplied_id
        SEQUENCES.pop(self.session, None)
        PREFIXES.pop(self.session, None)
        self.model = self.meta.get('model')
        self.tier = None
        self.position = 0
        self.needs_prefix = False
        if self.meta.get('forked_from_id'):
            ancestors(path)
            meta, seen = self.meta, set()
            while meta and meta.get('forked_from_id') and meta.get('id') not in seen:
                seen.add(meta.get('id'))
                if not isinstance(meta.get('subagent_history_start_ordinal'), int):
                    self.needs_prefix = True
                    break
                meta = ancestor_metadata(meta['forked_from_id'])

    def context(self, row):
        if row.get('type') == 'turn_context':
            payload = row.get('payload') or {}
            self.model = payload.get('model') or self.model
            self.tier = payload.get('service_tier')

    def restore_context(self, stream, offset):
        if self.needs_prefix:
            stream.seek(0)
            while stream.tell() < offset:
                try:
                    row = json.loads(stream.readline())
                    self.context(row)
                    if signature(row) is not None:
                        self.position += 1
                except (ValueError, TypeError, AttributeError):
                    continue
            return
        remainder = b''
        while offset:
            start = max(0, offset - 65536)
            stream.seek(start)
            parts = (stream.read(offset - start) + remainder).split(b'\n')
            remainder = parts[0]
            for line in reversed(parts[1:]):
                if b'"turn_context"' not in line:
                    continue
                try:
                    row = json.loads(line)
                    if row.get('type') == 'turn_context':
                        self.context(row)
                        return
                except (ValueError, AttributeError):
                    continue
            offset = start

    def owner(self, ordinal, position):
        meta, seen = self.meta, set()
        while meta.get('forked_from_id'):
            boundary = meta.get('subagent_history_start_ordinal')
            if not isinstance(boundary, int):
                own_sequence = sequence(meta['id'])
                if position >= len(own_sequence):
                    raise DeferredUsage('fork prefix changed during extraction')
                if position >= inherited_prefix(meta):
                    break
            else:
                if not isinstance(ordinal, int):
                    raise ValueError('fork usage has no ordinal')
                if ordinal >= boundary:
                    break
            parent = meta['forked_from_id']
            if parent in seen:
                raise ValueError('fork lineage cycle')
            seen.add(parent)
            ancestor = ancestor_metadata(parent)
            if ancestor is None:
                raise DeferredUsage('fork ancestor unavailable')
            if not isinstance(boundary, int):
                ordinal = sequence(parent)[position][1]
            meta = ancestor
        return meta.get('id') or self.session

    def event(self, row):
        self.context(row)
        payload = row.get('payload') or {}
        if row.get('type') != 'event_msg' or payload.get('type') != 'token_count':
            return None
        info = payload.get('info') or {}
        usage = info.get('last_token_usage')
        cumulative = (info.get('total_token_usage') or {}).get('total_tokens')
        position = self.position
        if signature(row) is not None:
            self.position += 1
        if not usage or not isinstance(cumulative, int) or not self.model:
            return None
        owner = self.owner(row.get('ordinal'), position)
        if not owner or not row.get('timestamp'):
            return None
        cached = count(usage.get('cached_input_tokens'))
        written = count(usage.get('cache_write_input_tokens'))
        output = count(usage.get('output_tokens'))
        tier = payload.get('service_tier') or self.tier
        owner_meta = METADATA.get(owner, self.meta)
        subagent = bool(parent_thread(owner_meta))
        return dict(type='usage', at=row['timestamp'], session_id=owner, model=self.model,
                    dedupe=f'{owner}:{cumulative}',
                    tokens=dict(input=max(0, count(usage.get('input_tokens')) - cached),
                                output=output, cache_read=cached, cache_write_5m=written,
                                cache_write_1h=0, reasoning=min(output, count(usage.get('reasoning_output_tokens')))),
                    tier=tier if tier in ('standard', 'priority', 'batch', 'flex', 'fast') else None,
                    cost_usd=None, subagent=subagent,
                    agent_id=owner if subagent else None,
                    fork_of=owner_meta.get('forked_from_id'))


if __name__ == '__main__':
    sys.exit(main(CodexUsage, defaults(), session_id))

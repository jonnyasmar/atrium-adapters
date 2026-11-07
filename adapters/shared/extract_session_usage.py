import argparse
import json
import os
import sys
import zlib
from pathlib import Path

TOKEN_KEYS = ('input', 'output', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'reasoning')


def emit(value):
    print(json.dumps(value, separators=(',', ':'), allow_nan=False))


def count(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def fold(old, new):
    if old is None:
        return new
    total = lambda e: sum(e['tokens'][k] for k in TOKEN_KEYS if k != 'reasoning')
    result = dict(new if total(new) > total(old) else old)
    result['tokens'] = {k: max(old['tokens'][k], new['tokens'][k]) for k in TOKEN_KEYS}
    costs = [e['cost_usd'] for e in (old, new) if e.get('cost_usd') is not None]
    result['cost_usd'] = max(costs) if costs else None
    return result


def checkpoint_offset(stream, token):
    if token is None:
        return 0, 0, False
    try:
        kind, offset, crc = token.split(':')
        offset, crc = int(offset), int(crc, 16)
        if kind != 'o' or offset < 0:
            raise ValueError()
        if offset == 0:
            if crc != 0:
                raise ValueError()
            return 0, 0, False
        stream.seek(0, 2)
        if offset > stream.tell():
            raise ValueError()
        stream.seek(offset - 1)
        if stream.read(1) != b'\n':
            raise ValueError()
        # Find only the previous complete line, not the whole transcript.
        end = offset - 1
        chunks = []
        while end:
            start = max(0, end - 8192)
            stream.seek(start)
            chunk = stream.read(end - start)
            marker = chunk.rfind(b'\n')
            chunks.append(chunk[marker + 1:])
            if marker >= 0:
                break
            end = start
        previous = b''.join(reversed(chunks)) + b'\n'
        if zlib.crc32(previous) != crc:
            raise ValueError()
        return offset, crc, False
    except (ValueError, AttributeError):
        return 0, 0, True


def extract(request, parser_factory):
    path, token = request['path'], request.get('resume')
    try:
        with open(path, 'rb') as stream:
            offset, crc, reset = checkpoint_offset(stream, token)
            parser = parser_factory(Path(path), request.get('session_id'))
            # Context-only replay is needed by rollouts whose model/session metadata
            # precedes the checkpoint; usage records themselves are never replayed.
            if offset and hasattr(parser, 'restore_context'):
                parser.restore_context(stream, offset)
            stream.seek(offset)
            events, malformed = {}, 0
            while True:
                line = stream.readline()
                if not line or not line.endswith(b'\n'):
                    break
                offset = stream.tell()
                crc = zlib.crc32(line)
                try:
                    row = json.loads(line)
                    if not isinstance(row, dict):
                        raise ValueError()
                    event = parser.event(row)
                    if event:
                        events[event['dedupe']] = fold(events.get(event['dedupe']), event)
                except (ValueError, TypeError, KeyError, AttributeError):
                    malformed += 1
            for event in events.values():
                emit(event)
            emit(dict(type='checkpoint', path=path, resume=f'o:{offset}:{crc:08x}',
                      complete=True, events=len(events), malformed=malformed, reset=reset))
    except OSError as error:
        emit(dict(type='checkpoint', path=path, resume=token, complete=False,
                  error=type(error).__name__))


def roots(defaults):
    test_root = os.environ.get('ATRIUM_TEST_TRANSCRIPT_ROOT')
    if test_root:
        return [Path(test_root)]
    extras = json.loads(os.environ.get('ATRIUM_USAGE_ROOTS', '[]'))
    if not isinstance(extras, list) or any(not isinstance(p, str) or not Path(p).is_absolute() for p in extras):
        raise ValueError('ATRIUM_USAGE_ROOTS must be a JSON array of absolute paths')
    return list(dict.fromkeys(Path(p).expanduser() for p in defaults + extras))


def discover(defaults, since, session_id):
    seen = set()
    for root in roots(defaults):
        for directory, dirs, files in os.walk(root, followlinks=False):
            dirs.sort()
            for name in sorted(files):
                if not name.endswith('.jsonl'):
                    continue
                path = Path(directory) / name
                try:
                    stat = path.stat()
                    identity = (stat.st_dev, stat.st_ino) if stat.st_ino else str(path.resolve())
                    if identity in seen or stat.st_mtime < since:
                        continue
                    seen.add(identity)
                    emit(dict(path=str(path.absolute()), session_id=session_id(path),
                              size=stat.st_size, mtime=int(stat.st_mtime)))
                except OSError:
                    continue


def main(parser_factory, defaults, session_id):
    args = argparse.ArgumentParser()
    args.add_argument('--usage', action='store_true', required=True)
    mode = args.add_mutually_exclusive_group(required=True)
    mode.add_argument('--batch', action='store_true')
    mode.add_argument('--list', action='store_true')
    args.add_argument('--max-files', type=int, default=500)
    args.add_argument('--since', type=float, default=0)
    try:
        options = args.parse_args()
        if options.max_files < 1:
            raise ValueError('--max-files must be positive')
        if options.list:
            discover(defaults, options.since, session_id)
        else:
            for index, line in enumerate(sys.stdin):
                if index >= options.max_files:
                    raise ValueError('batch exceeds --max-files')
                request = json.loads(line)
                if not isinstance(request, dict) or not isinstance(request.get('path'), str):
                    raise ValueError('request requires path')
                extract(request, parser_factory)
        return 0
    except SystemExit as error:
        return 0 if error.code == 0 else 10
    except (ValueError, TypeError) as error:
        print(f'extract_session: {error}', file=sys.stderr)
        return 10
    except OSError:
        return 3

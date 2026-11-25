"""The usage-only subset of agy's CortexStepMetadata protobuf (agy 2026-11-23)."""
from datetime import datetime, timezone


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError('truncated varint')
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError('oversized varint')


def fields(data):
    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError('invalid field')
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire in (1, 2, 5):
            if wire == 2:
                length, offset = varint(data, offset)
            else:
                length = 8 if wire == 1 else 4
            if length > len(data) - offset:
                raise ValueError('truncated field')
            value = data[offset:offset + length]
            offset += length
        else:
            raise ValueError('unsupported wire type')
        result[number] = value
    return result


def usage(metadata, session, index, fallback_model=None):
    step = fields(metadata)
    if 9 not in step:
        return None
    counts = fields(step[9])
    model = fields(step.get(24, b'')).get(8, b'').decode('utf-8')
    if not model and fallback_model:
        model = fallback_model(fields(step.get(20, b'')).get(3, 0))
    if not model:
        raise ValueError('missing model name')
    timestamp = fields(step.get(8, step.get(1, b'')))
    if 1 not in timestamp:
        raise ValueError('missing timestamp')
    seconds = timestamp[1] + timestamp.get(2, 0) / 1_000_000_000
    at = datetime.fromtimestamp(seconds, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    tokens = {key: counts.get(number, 0) for key, number in (
        ('input', 2), ('output', 3), ('cache_write_5m', 4), ('cache_read', 5), ('reasoning', 9))}
    tokens['cache_write_1h'] = 0
    if any(not isinstance(value, int) or value < 0 for value in tokens.values()):
        raise ValueError('invalid token count')
    if tokens['reasoning'] > tokens['output']:
        raise ValueError('reasoning exceeds output')
    origin = fields(step.get(20, b''))
    session = origin.get(1, session.encode()).decode('utf-8')
    index = origin.get(2, 0) if origin.get(1) else index
    # Input is already uncached; output already includes thinking. gen_metadata
    # repeats this same usage and must never be added as a second request.
    return dict(type='usage', at=at, session_id=session, model=model,
                dedupe=f'antigravity:{session}:step:{index}', tokens=tokens)

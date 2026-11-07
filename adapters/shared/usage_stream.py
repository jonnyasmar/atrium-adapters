import contextlib
import zlib
from pathlib import Path


@contextlib.contextmanager
def open_transcript(path):
    if str(path).endswith('.zst'):
        try:
            from compression import zstd
            stream = zstd.open(path, 'rb')
        except ImportError:
            try:
                import zstandard
                stream = zstandard.open(path, 'rb')
            except ImportError as error:
                raise OSError('compressed transcripts require Python 3.14 or zstandard') from error
        with stream:
            yield stream
    else:
        with open(path, 'rb') as stream:
            yield stream


def compressed_token(path):
    path = Path(path)
    stat = path.stat()
    with path.open('rb') as stream:
        stream.seek(max(0, stat.st_size - 65536))
        crc = zlib.crc32(stream.read())
    return f'z:{stat.st_size}:{stat.st_mtime_ns}:{crc:08x}'


def transcript_name(name):
    return name.endswith(('.jsonl', '.jsonl.zst'))

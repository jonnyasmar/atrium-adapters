"""Read-only, batched SQLite usage extraction shared by local database adapters."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
_shared_module_spec = importlib.util.spec_from_file_location(
    "_shared_transcript_usage", Path(__file__).with_name("extract_session_usage.py")
)
if _shared_module_spec is None or _shared_module_spec.loader is None:
    raise ImportError("shared transcript usage helpers are unavailable")
_shared_usage = importlib.util.module_from_spec(_shared_module_spec)
_shared_module_spec.loader.exec_module(_shared_usage)
count, fold = _shared_usage.count, _shared_usage.fold


def emit(value: dict) -> None:
    print(json.dumps(value, separators=(",", ":"), ensure_ascii=False, allow_nan=False))


def normalize_at(value) -> str:
    if isinstance(value, bool) or value is None:
        raise ValueError("usage timestamp is missing")
    if isinstance(value, (int, float)):
        seconds = float(value)
        if abs(seconds) >= 100_000_000_000:
            seconds /= 1000
        return datetime.fromtimestamp(seconds, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    if not isinstance(value, str) or not value:
        raise ValueError("usage timestamp is invalid")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("usage timestamp has no timezone")
    return parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def open_ro(path: str) -> sqlite3.Connection:
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=1)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only = ON")
    conn.execute("PRAGMA busy_timeout = 1000")
    conn.execute("BEGIN")
    return conn


def usage_roots() -> list[Path]:
    try:
        raw_roots = json.loads(os.environ.get("ATRIUM_USAGE_ROOTS", "[]"))
    except json.JSONDecodeError as error:
        raise ValueError("ATRIUM_USAGE_ROOTS must be a JSON array of absolute paths") from error
    if not isinstance(raw_roots, list) or any(
        not isinstance(root, str) or not Path(root).is_absolute() for root in raw_roots
    ):
        raise ValueError("ATRIUM_USAGE_ROOTS must be a JSON array of absolute paths")
    return [Path(root).expanduser() for root in raw_roots]


def file_entry(path: Path, session_id=None, since=0) -> dict | None:
    try:
        stat = path.stat()
        wal = Path(str(path) + "-wal")
        try:
            wal_stat = wal.stat()
            size = stat.st_size + wal_stat.st_size
            mtime = max(stat.st_mtime, wal_stat.st_mtime)
        except OSError:
            size, mtime = stat.st_size, stat.st_mtime
        if mtime < since:
            return None
        item = {"path": str(path.absolute()), "session_id": session_id, "size": size, "mtime": int(mtime)}
        return item
    except OSError:
        return None


def _checkpoint(item, resume, *, complete, events=0, malformed=0, reset=False, error=None):
    result = {"type": "checkpoint", "path": item["path"], "resume": resume,
              "complete": complete, "events": events, "malformed": malformed, "reset": reset}
    if error:
        result["error"] = error
    emit(result)


def _extract(item, request, adapter, page_size):
    resume = request.get("resume")
    connection = None
    try:
        connection = open_ro(item["path"])
        if not adapter.has_usage_schema(connection):
            _checkpoint(item, resume, complete=False, error="unsupported-native-schema")
            return
        cursor, reset = adapter.select(connection, resume)
        event_count = 0
        malformed = 0
        next_resume = resume or "r:0"
        while True:
            rows = cursor.fetchmany(page_size)
            if not rows:
                break
            events = {}
            for row in rows:
                try:
                    next_resume = adapter.resume_after(row)
                except (ValueError, TypeError, KeyError, IndexError):
                    malformed += 1
                    continue
                try:
                    event = adapter.event(row, item)
                    if event is None:
                        continue
                    event["at"] = normalize_at(event["at"])
                    if not isinstance(event.get("dedupe"), str) or not event["dedupe"]:
                        raise ValueError("usage event has no dedupe key")
                    events[event["dedupe"]] = fold(events.get(event["dedupe"]), event)
                except (ValueError, TypeError, KeyError, IndexError, OverflowError, OSError):
                    malformed += 1
            for event in events.values():
                emit(event)
                event_count += 1
            sys.stdout.flush()
        _checkpoint(item, next_resume, complete=True, events=event_count, malformed=malformed, reset=reset)
    except (OSError, sqlite3.Error) as error:
        _checkpoint(item, resume, complete=False, error=type(error).__name__)
    except Exception as error:  # An adapter callback failure is isolated to its source file.
        _checkpoint(item, resume, complete=False, error=type(error).__name__)
    finally:
        if connection is not None:
            connection.close()


def main(adapter, argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usage", action="store_true", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--batch", action="store_true")
    mode.add_argument("--list", action="store_true")
    parser.add_argument("--max-files", type=int, default=500)
    parser.add_argument("--since", type=float, default=0)
    parser.add_argument("--page-size", type=int, default=512)
    try:
        options = parser.parse_args(argv)
        if options.max_files < 1 or options.page_size < 1:
            raise ValueError("--max-files and --page-size must be positive")
        if options.list:
            for path in adapter.discover(options.since):
                item = file_entry(Path(path), since=options.since)
                if item:
                    emit(item)
            return 0
        for index, line in enumerate(sys.stdin):
            if index >= options.max_files:
                raise ValueError("batch exceeds --max-files")
            request = json.loads(line)
            if not isinstance(request, dict) or not isinstance(request.get("path"), str):
                raise ValueError("request requires path")
            item = {"path": request["path"]}
            _extract(item, request, adapter, options.page_size)
        return 0
    except SystemExit as error:
        return 0 if error.code == 0 else 10
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        print(f"extract_session: {error}", file=sys.stderr)
        return 10
    except OSError as error:
        print(f"extract_session: {error}", file=sys.stderr)
        return 3

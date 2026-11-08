from __future__ import annotations

import math
import os
import sqlite3
import sys
from pathlib import Path

USAGE_OUTPUT_VERSION = 1


def shared_dir():
    # <data>/adapters/<name> links to .managed/<name>/generations/<id>, whose
    # resolved parent is not the adapters dir: try the logical path first.
    for adapter in (Path(os.path.abspath(__file__)).parent, Path(__file__).resolve().parent):
        parts = adapter.parts
        managed = len(parts) > 4 and parts[-4] == ".managed" and parts[-2] == "generations"
        shared = (Path(*parts[:-4]) if managed else adapter.parent) / "shared"
        if shared.is_dir():
            return str(shared)
    sys.exit(f"extract_session: no shared/ runtime found from {__file__}")


sys.path.insert(0, shared_dir())
from sqlite_usage import count, main, usage_roots


def database_path() -> Path:
    fixture_root = os.environ.get("ATRIUM_TEST_TRANSCRIPT_ROOT")
    if fixture_root:
        return Path(fixture_root) / "sessions.db"
    root = os.environ.get("GOOSE_PATH_ROOT", "")
    if root and Path(root).is_absolute():
        return Path(root) / "data/sessions/sessions.db"
    data_home = os.environ.get("XDG_DATA_HOME")
    if data_home:
        return Path(data_home) / "goose/sessions/sessions.db"
    return Path.home() / ".local/share/goose/sessions/sessions.db"


class GooseUsage:
    def discover(self, since):
        candidates = [database_path()]
        for path in usage_roots():
            if path.name == "sessions.db":
                candidates.append(path)
            elif path.name == "sessions":
                candidates.append(path / "sessions.db")
            elif path.name == "goose":
                candidates.append(path / "sessions/sessions.db")
            elif os.environ.get("GOOSE_PATH_ROOT") and Path(os.environ["GOOSE_PATH_ROOT"]).expanduser() == path:
                candidates.append(path / "data/sessions/sessions.db")
            elif os.environ.get("XDG_DATA_HOME") and Path(os.environ["XDG_DATA_HOME"]).expanduser() == path:
                candidates.append(path / "goose/sessions/sessions.db")
            else:
                candidates.append(path / "data/sessions/sessions.db")
        seen = set()
        for path in candidates:
            absolute = path.absolute()
            if str(absolute) not in seen:
                seen.add(str(absolute))
                yield absolute

    def has_usage_schema(self, conn):
        exists = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='usage_ledger'"
        ).fetchone()
        if not exists:
            return False
        columns = {row[1] for row in conn.execute("PRAGMA table_info(usage_ledger)")}
        required = {
            "id", "session_id", "created_timestamp", "model", "input_tokens", "output_tokens",
            "total_tokens", "cache_read_tokens", "cache_write_tokens", "cost", "cost_source",
        }
        if not required.issubset(columns):
            raise sqlite3.DatabaseError("usage_ledger schema is incomplete")
        return True

    def select(self, conn, resume):
        reset = False
        start = 0
        if resume is not None:
            try:
                prefix, raw = resume.split(":", 1)
                start = int(raw)
                if prefix != "r" or start < 0:
                    raise ValueError()
            except (ValueError, TypeError):
                start, reset = 0, True
        cursor = conn.execute(
            "SELECT id, session_id, created_timestamp, model, input_tokens, output_tokens, total_tokens, "
            "cache_read_tokens, cache_write_tokens, cost, cost_source "
            "FROM usage_ledger WHERE id > ? ORDER BY id",
            (start,),
        )
        return cursor, reset

    def resume_after(self, row):
        return f"r:{int(row['id'])}"

    def event(self, row, item):
        if row["cost_source"] == "carried_forward":
            return None
        if not isinstance(row["session_id"], str) or not row["session_id"]:
            raise ValueError("usage ledger row has no session id")
        raw_input = count(row["input_tokens"])
        cache_read = count(row["cache_read_tokens"])
        cache_write = count(row["cache_write_tokens"])
        model = row["model"] if isinstance(row["model"], str) and row["model"].strip() else "__none"
        cost = None
        if row["cost_source"] == "provider_reported":
            cost = row["cost"]
            if (
                isinstance(cost, bool)
                or not isinstance(cost, (int, float))
                or not math.isfinite(cost)
                or cost < 0
            ):
                raise ValueError("provider-reported usage cost is invalid")
        return {
            "type": "usage",
            "at": row["created_timestamp"],
            "session_id": row["session_id"],
            "model": model,
            "dedupe": f"goose:{row['session_id']}:{row['id']}",
            "tokens": {
                "input": max(raw_input - cache_read - cache_write, 0),
                "output": count(row["output_tokens"]),
                "cache_read": cache_read,
                "cache_write_5m": cache_write,
                "cache_write_1h": 0,
                "reasoning": 0,
            },
            "tier": None,
            "cost_usd": cost,
            "subagent": False,
            "agent_id": None,
            "fork_of": None,
        }


if __name__ == "__main__":
    raise SystemExit(main(GooseUsage()))

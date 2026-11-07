import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
GOOSE = HERE.parents[2]
sys.path.insert(0, str(GOOSE))
sys.path.insert(0, str(GOOSE.parent / "shared"))
from sqlite_usage import main


class TrackingCursor:
    def __init__(self, cursor, total_rows):
        self.cursor = cursor
        self.total_rows = total_rows
        self.rows_read = 0
        self.max_batch = 0

    def fetchmany(self, size):
        rows = self.cursor.fetchmany(size)
        self.rows_read += len(rows)
        self.max_batch = max(self.max_batch, len(rows))
        return rows


class StreamingAdapter:
    def __init__(self, total_rows):
        self.total_rows = total_rows
        self.tracker = None
        self.calls_since_emit = 0

    def discover(self, since):
        return []

    def has_usage_schema(self, conn):
        return True

    def select(self, conn, resume):
        cursor = TrackingCursor(conn.execute("SELECT id FROM rows ORDER BY id"), self.total_rows)
        self.tracker = cursor
        return cursor, False

    def resume_after(self, row):
        return f"r:{row['id']}"

    def event(self, row, item):
        self.calls_since_emit += 1
        return {
            "type": "usage",
            "at": 1794000000,
            "session_id": "synthetic-stream",
            "model": "synthetic-model",
            "dedupe": "same-request",
            "tokens": {"input": row["id"], "output": 1, "cache_read": 0,
                       "cache_write_5m": 0, "cache_write_1h": 0, "reasoning": 0},
            "tier": None,
            "cost_usd": None,
            "subagent": False,
            "agent_id": None,
            "fork_of": None,
        }


class ObserveOutput(io.StringIO):
    def __init__(self, adapter):
        super().__init__()
        self.adapter = adapter
        self.first_output_rows_read = None
        self.max_rows_buffered = 0

    def write(self, value):
        if '"type":"usage"' in value and self.adapter.calls_since_emit:
            if self.first_output_rows_read is None:
                self.first_output_rows_read = self.adapter.tracker.rows_read
            self.max_rows_buffered = max(self.max_rows_buffered, self.adapter.calls_since_emit)
            self.adapter.calls_since_emit = 0
        return super().write(value)


class SqliteUsageStreamingTests(unittest.TestCase):
    def test_usage_flushes_by_bounded_page_before_cursor_exhaustion(self):
        total_rows, page_size = 101, 13
        with tempfile.TemporaryDirectory() as temporary:
            db = Path(temporary) / "synthetic.db"
            with sqlite3.connect(db) as connection:
                connection.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY)")
                connection.executemany("INSERT INTO rows VALUES (?)", ((index,) for index in range(1, total_rows + 1)))

            adapter = StreamingAdapter(total_rows)
            output = ObserveOutput(adapter)
            request = io.StringIO(json.dumps({"path": str(db)}) + "\n")
            with contextlib.redirect_stdout(output), patch("sys.stdin", request):
                self.assertEqual(main(adapter, ["--usage", "--batch", "--page-size", str(page_size)]), 0)
            lines = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(adapter.tracker.max_batch, page_size)
            self.assertEqual(output.max_rows_buffered, page_size)
            self.assertEqual(output.first_output_rows_read, page_size)
            self.assertLess(output.first_output_rows_read, total_rows)
            self.assertEqual(lines[-1]["resume"], f"r:{total_rows}")


if __name__ == "__main__":
    unittest.main()

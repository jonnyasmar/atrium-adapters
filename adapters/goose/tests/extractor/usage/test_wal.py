import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
GOOSE = HERE.parents[2]
sys.path.insert(0, str(GOOSE))
from extract_session_usage import GooseUsage
from sqlite_usage import file_entry, main


class SqliteUsageWalTests(unittest.TestCase):
    def test_ro_snapshot_sees_wal_and_resume_sees_appended_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            db = Path(temporary) / "sessions.db"
            writer = sqlite3.connect(db)
            writer.execute("PRAGMA journal_mode=WAL")
            writer.executescript((HERE / "fixture.sql").read_text())
            writer.commit()
            before = file_entry(db)
            self.assertTrue(Path(str(db) + "-wal").exists())

            listing = io.StringIO()
            with contextlib.redirect_stdout(listing), patch.dict(
                os.environ, {"ATRIUM_TEST_TRANSCRIPT_ROOT": temporary, "ATRIUM_USAGE_ROOTS": "[]"}
            ):
                self.assertEqual(main(GooseUsage(), ["--usage", "--list"]), 0)
            before_listed = json.loads(listing.getvalue())
            self.assertEqual(before_listed["path"], str(db))

            durations = []
            first_lines = []
            for _ in range(5):
                output = io.StringIO()
                started = time.perf_counter()
                with contextlib.redirect_stdout(output), patch(
                    "sys.stdin", io.StringIO(json.dumps({"path": str(db)}) + "\n")
                ):
                    self.assertEqual(main(GooseUsage(), ["--usage", "--batch", "--page-size", "1"]), 0)
                durations.append(time.perf_counter() - started)
                first_lines = [json.loads(line) for line in output.getvalue().splitlines()]
            checkpoint = first_lines[-1]
            self.assertEqual(checkpoint["resume"], "r:13")
            average = sum(durations) / len(durations)
            self.assertLess(average, 0.05, f"live-WAL average was {average * 1000:.1f} ms per file")

            writer.execute(
                "INSERT INTO usage_ledger VALUES (14, 'synthetic-session', 1794000003, "
                "'provider/model-alpha', 12, 5, 17, 2, 0, NULL, NULL, 0)"
            )
            writer.commit()
            after = file_entry(db)
            self.assertGreater(after["size"], before["size"])

            listing = io.StringIO()
            with contextlib.redirect_stdout(listing), patch.dict(
                os.environ, {"ATRIUM_TEST_TRANSCRIPT_ROOT": temporary, "ATRIUM_USAGE_ROOTS": "[]"}
            ):
                self.assertEqual(main(GooseUsage(), ["--usage", "--list"]), 0)
            after_listed = json.loads(listing.getvalue())
            self.assertGreater(after_listed["size"], before_listed["size"])

            output = io.StringIO()
            with contextlib.redirect_stdout(output), patch(
                "sys.stdin", io.StringIO(json.dumps({"path": str(db), "resume": "r:13"}) + "\n")
            ):
                self.assertEqual(main(GooseUsage(), ["--usage", "--batch"]), 0)
            second_lines = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([line["dedupe"] for line in second_lines if line["type"] == "usage"],
                             ["goose:synthetic-session:14"])
            writer.close()


if __name__ == "__main__":
    unittest.main()

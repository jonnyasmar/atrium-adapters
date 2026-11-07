import hashlib
import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GOOSE = HERE.parents[2]
SCRIPT = GOOSE / "extract_session.sh"


class GooseUsageTests(unittest.TestCase):
    def test_batch_resume_list_and_source_immutability(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            db = root / "sessions.db"
            subprocess.run(
                ["python3", str(HERE / "build-fixture.py"), str(HERE / "fixture.sql"), str(db)],
                check=True,
            )
            env = {
                **os.environ,
                "ATRIUM_TEST_TRANSCRIPT_ROOT": temporary,
                "ATRIUM_USAGE_ROOTS": "[]",
            }
            before = hashlib.sha256(db.read_bytes()).hexdigest()

            result = subprocess.run(
                [str(SCRIPT), "--usage", "--batch", "--page-size", "1"],
                input=json.dumps({"path": str(db)}) + "\n",
                text=True,
                capture_output=True,
                env=env,
                check=True,
            )
            lines = [json.loads(line) for line in result.stdout.splitlines()]
            expected = (HERE / "expected-usage.jsonl").read_text().splitlines()
            self.assertEqual([json.dumps(line, separators=(",", ":"), ensure_ascii=False) for line in lines[:-1]], expected)
            self.assertEqual(lines[-1]["resume"], "r:13")

            resumed = subprocess.run(
                [str(SCRIPT), "--usage", "--batch", "--page-size", "1"],
                input=json.dumps({"path": str(db), "resume": "r:11"}) + "\n",
                text=True,
                capture_output=True,
                env=env,
                check=True,
            )
            resumed_lines = [json.loads(line) for line in resumed.stdout.splitlines()]
            self.assertEqual([line["dedupe"] for line in resumed_lines if line["type"] == "usage"],
                             ["goose:synthetic-session:12"])
            self.assertEqual(resumed_lines[-1]["resume"], "r:13")

            listed = subprocess.run(
                [str(SCRIPT), "--usage", "--list"],
                text=True,
                capture_output=True,
                env=env,
                check=True,
            )
            entries = [json.loads(line) for line in listed.stdout.splitlines()]
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0], {"path": str(db), "session_id": None,
                                          "size": db.stat().st_size, "mtime": int(db.stat().st_mtime)})
            self.assertEqual(hashlib.sha256(db.read_bytes()).hexdigest(), before)

    def test_legacy_database_without_request_ledger_is_unrecorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            db = Path(temporary) / "sessions.db"
            with sqlite3.connect(db) as connection:
                connection.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
            result = subprocess.run(
                [str(SCRIPT), "--usage", "--batch"],
                input=json.dumps({"path": str(db), "resume": "r:27"}) + "\n",
                text=True,
                capture_output=True,
                env={**os.environ, "ATRIUM_USAGE_ROOTS": "[]"},
                check=True,
            )
            checkpoint = json.loads(result.stdout)
            self.assertEqual(checkpoint["resume"], "unsupported-schema")
            self.assertTrue(checkpoint["complete"])
            self.assertEqual(checkpoint["unrecorded"], {"reason": "unsupported-schema", "count": 1})
            self.assertNotIn("error", checkpoint)
            with sqlite3.connect(db) as connection:
                connection.execute("DROP TABLE sessions")
                connection.executescript((HERE / "fixture.sql").read_text())
            resumed = subprocess.run(
                [str(SCRIPT), "--usage", "--batch"],
                input=json.dumps({"path": str(db), "resume": checkpoint["resume"]}) + "\n",
                text=True, capture_output=True, check=True,
            )
            lines = [json.loads(line) for line in resumed.stdout.splitlines()]
            self.assertEqual(len([row for row in lines if row["type"] == "usage"]), 2)
            self.assertTrue(lines[-1]["reset"])
            self.assertNotIn("unrecorded", lines[-1])

    def test_corrupt_and_incomplete_ledgers_remain_retryable_failures(self):
        for kind in ("corrupt", "incomplete"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                db = Path(temporary) / "sessions.db"
                if kind == "corrupt":
                    db.write_bytes(b"invented non-SQLite database bytes")
                else:
                    with sqlite3.connect(db) as connection:
                        connection.execute("CREATE TABLE usage_ledger (id INTEGER PRIMARY KEY)")
                result = subprocess.run(
                    [str(SCRIPT), "--usage", "--batch"],
                    input=json.dumps({"path": str(db), "resume": "r:27"}) + "\n",
                    text=True, capture_output=True, check=True,
                )
                checkpoint = json.loads(result.stdout)
                self.assertFalse(checkpoint["complete"])
                self.assertEqual(checkpoint["resume"], "r:27")
                self.assertEqual(checkpoint["error"], "DatabaseError")
                self.assertNotIn("unrecorded", checkpoint)

    def test_one_process_two_hundred_file_batch_stays_under_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            db = Path(temporary) / "sessions.db"
            with sqlite3.connect(db) as connection:
                connection.executescript((HERE / "fixture.sql").read_text())
            started = time.perf_counter()
            result = subprocess.run(
                [str(SCRIPT), "--usage", "--batch"],
                input=(json.dumps({"path": str(db)}) + "\n") * 200,
                text=True, capture_output=True, check=True,
            )
            elapsed = time.perf_counter() - started
            checkpoints = [json.loads(line) for line in result.stdout.splitlines() if '"type":"checkpoint"' in line]
            self.assertEqual(len(checkpoints), 200)
            self.assertLess(elapsed / 200, 0.05)
            print(f"[PASS] one 200-file batch: {elapsed * 1000 / 200:.3f} ms/file")

    def test_bad_provider_reported_cost_isolated_as_malformed_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            db = root / "sessions.db"
            subprocess.run(
                ["python3", str(HERE / "build-fixture.py"), str(HERE / "fixture.sql"), str(db)],
                check=True,
            )
            with sqlite3.connect(db) as connection:
                connection.executemany(
                    "INSERT INTO usage_ledger (id, session_id, created_timestamp, model, input_tokens, "
                    "output_tokens, total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source) "
                    "VALUES (?, 'synthetic-session', 1794000003, 'synthetic-model', 1, 1, 2, 0, 0, ?, 'provider_reported')",
                    [(14, -0.1), (15, None)],
                )
            result = subprocess.run(
                [str(SCRIPT), "--usage", "--batch"],
                input=json.dumps({"path": str(db)}) + "\n",
                text=True,
                capture_output=True,
                env={**os.environ, "ATRIUM_TEST_TRANSCRIPT_ROOT": temporary, "ATRIUM_USAGE_ROOTS": "[]"},
                check=True,
            )
            lines = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual([line["type"] for line in lines], ["usage", "usage", "checkpoint"])
            self.assertEqual(lines[-1]["malformed"], 2)
            self.assertEqual(lines[-1]["resume"], "r:15")

    def test_usage_roots_require_absolute_json_array(self):
        for value in ('"relative"', '["relative"]', '{"root":"/tmp"}'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temporary:
                env = {**os.environ, "ATRIUM_USAGE_ROOTS": value,
                       "ATRIUM_TEST_TRANSCRIPT_ROOT": temporary}
                result = subprocess.run([str(SCRIPT), "--usage", "--list"],
                                        text=True, capture_output=True, env=env)
                self.assertEqual(result.returncode, 10)
                self.assertIn("ATRIUM_USAGE_ROOTS must be a JSON array", result.stderr)


if __name__ == "__main__":
    unittest.main()

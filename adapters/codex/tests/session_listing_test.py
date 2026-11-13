import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ADAPTER = Path(__file__).resolve().parents[1]
CWD = "/fixture/project"

# Observe the real Python interpreter and the shell's legacy fallback without
# adding instrumentation to the shipped script.
OBSERVER = r'''
import atexit, json, os, sys
counts = {"rollout_opens": 0, "rollout_stats": 0, "directory_scans": 0,
          "registry_connections": 0}
def audit(event, args):
    if event == "open" and str(args[0]).endswith(".jsonl"):
        counts["rollout_opens"] += 1
    elif event == "os.scandir":
        counts["directory_scans"] += 1
    elif event == "sqlite3.connect":
        counts["registry_connections"] += 1
sys.addaudithook(audit)
stat = os.stat
def counted_stat(path, *args, **kwargs):
    if str(path).endswith(".jsonl"):
        counts["rollout_stats"] += 1
    return stat(path, *args, **kwargs)
os.stat = counted_stat
def finish():
    with open(os.environ["WORK_LOG"], "a") as log:
        log.write(json.dumps(counts) + "\n")
atexit.register(finish)
'''


class CodexSessionListingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-list-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.codex = self.root / ".codex"
        self.rollouts = self.codex / "sessions/2026/11/12"
        self.rollouts.mkdir(parents=True)
        self.db = self.codex / "state_5.sqlite"
        self.work_log = self.root / "work.json"
        self.cli_log = self.root / "sqlite-cli.log"
        observer = self.root / "observer"
        observer.mkdir()
        (observer / "sitecustomize.py").write_text(OBSERVER)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "python3").symlink_to(sys.executable)
        sqlite_cli = shutil.which("sqlite3")
        self.assertIsNotNone(sqlite_cli, "sqlite3 is needed to exercise legacy fallback")
        wrapper = bin_dir / "sqlite3"
        wrapper.write_text(
            '#!/bin/sh\nprintf "called\\n" >> "$SQLITE_CLI_LOG"\n'
            'exec "$REAL_SQLITE_CLI" "$@"\n'
        )
        wrapper.chmod(0o755)
        self.env = dict(
            os.environ, HOME=str(self.root),
            PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
            PYTHONPATH=str(observer), WORK_LOG=str(self.work_log),
            SQLITE_CLI_LOG=str(self.cli_log), REAL_SQLITE_CLI=sqlite_cli,
        )

    def registry(self, modern=True):
        with sqlite3.connect(self.db) as conn:
            conn.execute("""CREATE TABLE threads (
                id TEXT, cwd TEXT, title TEXT, updated_at INTEGER,
                first_user_message TEXT, archived INTEGER)""")
            if modern:
                for column in ("thread_source TEXT", "rollout_path TEXT", "recency_at_ms INTEGER"):
                    conn.execute("ALTER TABLE threads ADD COLUMN " + column)
            conn.execute("CREATE INDEX threads_cwd ON threads(cwd)")

    def rollout(self, sid, cwd=CWD):
        path = self.rollouts / ("rollout-" + sid + ".jsonl")
        path.write_text(json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": cwd}}) + "\n")
        return path

    def listing(self):
        self.work_log.unlink(missing_ok=True)
        self.cli_log.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", str(ADAPTER / "list_recent_sessions.sh"), CWD],
            env=self.env, capture_output=True, text=True, check=True, timeout=5,
        )
        runs = [json.loads(line) for line in self.work_log.read_text().splitlines()]
        self.assertEqual(len(runs), 1, "one interpreter per listing")
        return json.loads(result.stdout)["sessions"], runs[0]

    def test_empty_registry_does_not_resurrect_an_unregistered_rollout(self):
        self.registry()
        self.rollout("not-in-registry")
        rows, work = self.listing()
        self.assertEqual(rows, [])
        self.assertEqual(work["rollout_opens"], 0)
        self.assertFalse(self.cli_log.exists(), "empty is final at the shell layer too")

    def test_empty_registry_work_does_not_grow_with_rollout_history(self):
        self.registry()
        previous = 0
        for size in (10, 100, 1000):
            with self.subTest(rollouts=size):
                for i in range(previous, size):
                    self.rollout(str(i), cwd="/unrelated")
                previous = size
                rows, work = self.listing()
                self.assertEqual(rows, [])
                self.assertEqual(work, {
                    "rollout_opens": 0, "rollout_stats": 0,
                    "directory_scans": 0, "registry_connections": 1,
                })
                self.assertFalse(self.cli_log.exists())

    def test_registry_with_only_ineligible_or_missing_rollouts_is_final(self):
        self.registry()
        source = self.rollout("archived")
        with sqlite3.connect(self.db) as conn:
            conn.executemany("INSERT INTO threads VALUES(?, ?, '', 1, '', ?, ?, ?, 1000)", [
                ("archived", CWD, 1, "user", str(source)),
                ("child", CWD, 0, "subagent", str(source)),
                ("missing", CWD, 0, "user", str(self.root / "missing.jsonl")),
            ])
        rows, work = self.listing()
        self.assertEqual(rows, [])
        self.assertEqual(work["rollout_opens"], 0)
        self.assertFalse(self.cli_log.exists())

    def test_registry_session_keeps_its_title_and_activity(self):
        self.registry()
        source = self.rollout("direct")
        with sqlite3.connect(self.db) as conn:
            conn.execute("INSERT INTO threads VALUES('direct', ?, 'title', 1, '', 0, 'user', ?, 2000)",
                         (CWD, str(source)))
        rows, work = self.listing()
        self.assertEqual(rows, [{
            "id": "direct", "name": "title", "cwd": CWD,
            "lastActive": "1970-01-01T00:00:02Z", "sourcePath": str(source),
        }])
        self.assertEqual(work["rollout_opens"], 0)
        self.assertEqual(work["rollout_stats"], 1)
        self.assertFalse(self.cli_log.exists())

    def test_missing_or_invalid_registry_keeps_rollout_compatibility(self):
        for broken in (False, True):
            with self.subTest(broken=broken):
                if broken:
                    self.db.write_text("invalid sqlite")
                self.rollout("legacy-rollout")
                rows, work = self.listing()
                self.assertEqual([row["id"] for row in rows], ["legacy-rollout"])
                self.assertEqual(work["rollout_opens"], 1)

    def test_legacy_registry_without_rollouts_still_uses_sqlite_fallback(self):
        self.registry(modern=False)
        with sqlite3.connect(self.db) as conn:
            conn.execute("INSERT INTO threads VALUES('legacy', ?, 'title', 1, '', 0)", (CWD,))
        rows, _ = self.listing()
        self.assertEqual([row["id"] for row in rows], ["legacy"])
        self.assertTrue(self.cli_log.exists())


if __name__ == "__main__":
    unittest.main()

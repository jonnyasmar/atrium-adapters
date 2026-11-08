from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('layout', ROOT / 'tests/installed-layout.py')
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)
ADAPTERS = ('codex', 'opencode')


class InstalledLookup(unittest.TestCase):
    def sandbox(self, name):
        box = layout.Sandbox(self, adapters=('shared', name))
        marker = box.home / 'recursive-search'
        find = box.home / 'bin/find'
        find.write_text('#!/bin/sh\ntouch "$HOME/recursive-search"\nexit 99\n')
        find.chmod(0o755)
        (box.home / 'sitecustomize.py').write_text('import glob\ndef forbidden(*a, **k):\n raise AssertionError("broad glob")\nglob.glob = forbidden\n')
        box.env['PYTHONPATH'] = str(box.home)
        return box, marker

    def invoke(self, box, name, sid='session-123', cwd='/work/proj', expected=0):
        result = subprocess.run([str(box.script(name, 'extract_session.sh')), '--session-id', sid,
            '--cwd', cwd, '--depth', 'quick'], env=box.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def write(self, path, text='{}\n'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_known_paths_without_recursive_discovery(self):
        for name in ADAPTERS:
            with self.subTest(adapter=name):
                box, marker = self.sandbox(name)
                home = box.home
                if name == 'codex':
                    path = self.write(home / '.codex/sessions/2026/11/08/rollout-exact.jsonl')
                    with closing(sqlite3.connect(home / '.codex/state_5.sqlite')) as conn, conn:
                        conn.execute('create table threads (id text primary key, rollout_path text)')
                        conn.execute('insert into threads values (?, ?)', ('session-123', str(path)))
                else:
                    self.write(home / '.local/share/opencode/project/hash/storage/session/info/ses_session-123.json', '{"id":"session-123"}')
                self.invoke(box, name)
                self.assertFalse(marker.exists())

    def test_missing_returns_not_found(self):
        for name in ADAPTERS:
            with self.subTest(adapter=name):
                box, marker = self.sandbox(name)
                for root in ('.codex/sessions', '.local/share/opencode'):
                    (box.home / root).mkdir(parents=True)
                box.env.pop('PYTHONPATH', None)
                self.invoke(box, name, expected=1)
                self.assertFalse(marker.exists())

    def test_codex_registry_requires_an_index(self):
        box, _ = self.sandbox('codex')
        home = box.home / 'custom-codex'
        home.mkdir()
        spec = importlib.util.spec_from_file_location('codex_paths', ROOT / 'adapters/codex/session_path.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Refuse an unindexed native table instead of silently doing a table scan.
        with closing(sqlite3.connect(home / 'state_5.sqlite')) as conn, conn:
            conn.execute('create table threads (id text, rollout_path text)')
            conn.execute('insert into threads values (?, ?)', ('legacy-id', str(self.write(home / 'existing.jsonl'))))
        self.assertIsNone(module.registry_path(home, 'legacy-id'))
        with closing(sqlite3.connect(home / 'state_5.sqlite')) as conn, conn:
            conn.execute('create unique index thread_id on threads(id)')
        self.assertEqual(module.registry_path(home, 'legacy-id'), home / 'existing.jsonl')

    def test_opencode_reads_only_project_names_and_caches_exact_identity(self):
        box, _ = self.sandbox('opencode')
        root = box.home / '.local/share/opencode'
        path = self.write(root / 'project/hash/storage/session/info/ses_session-123.json', '{}')
        self.write(root / 'project/another/deep/unrelated.json')
        spec = importlib.util.spec_from_file_location('opencode_paths', ROOT / 'adapters/opencode/session_path.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        scandir = os.scandir
        def only_root(directory):
            self.assertEqual(Path(directory), root / 'project')
            return scandir(directory)
        with patch.dict(os.environ, box.env), patch('os.scandir', side_effect=only_root):
            self.assertEqual(module.find_transcript('session-123'), path)
            with patch('os.scandir', side_effect=AssertionError('cache enumerated')):
                self.assertEqual(module.find_transcript('session-123'), path)
            self.assertEqual(module.messages_directory(path), path.parent.parent / 'messages/ses_session-123')
            path.unlink()
            moved = self.write(root / 'storage/session_diff/ses_session-123.json', '{}')
            self.assertEqual(module.find_transcript('session-123'), moved)
            with patch('os.scandir', side_effect=AssertionError('flat lookup enumerated')):
                self.assertEqual(module.find_transcript('ses_session-123'), moved)

    def test_codex_legacy_discovery_survives_absent_or_unusable_registry(self):
        for mode in ('absent', 'unindexed', 'empty', 'corrupt', 'stale'):
            with self.subTest(registry=mode):
                box, _ = self.sandbox('codex')
                guarded = box.env.pop('PYTHONPATH')
                home = box.home / '.codex'
                sid = '12345678-1234-4234-8234-123456789abc'
                path = self.write(home / 'sessions/2020/01/02/rollout-unrelated-name.jsonl',
                    json.dumps({'type': 'session_meta', 'payload': json.dumps({'id': sid})}) + '\n')
                self.write(home / 'sessions/2026/11/08/rollout-malformed.jsonl', '{broken\n')
                database = home / 'state_5.sqlite'
                if mode == 'corrupt':
                    database.write_text('not sqlite')
                elif mode != 'absent':
                    with closing(sqlite3.connect(database)) as conn, conn:
                        key = '' if mode == 'unindexed' else ' PRIMARY KEY'
                        conn.execute('create table threads(id TEXT' + key + ', rollout_path TEXT)')
                        if mode != 'empty':
                            conn.execute('insert into threads values (?, ?)', (sid, str(home / 'deleted.jsonl')))
                self.invoke(box, 'codex', sid=sid)
                # A successful slow lookup seeds the normal no-scan fast path.
                box.env['PYTHONPATH'] = guarded
                self.invoke(box, 'codex', sid=sid)
                path.unlink()
                moved = self.write(home / 'sessions/2019/02/03/rollout-moved.jsonl',
                    json.dumps({'type': 'session_meta', 'payload': {'id': sid}}) + '\n')
                box.env.pop('PYTHONPATH')
                self.invoke(box, 'codex', sid=sid)
                self.assertTrue(moved.is_file())

    def test_codex_non_uuid_id_and_v7_in_an_unexpected_partition(self):
        for sid in ('legacy-session', '019a61b8-0000-7000-8000-000000000001'):
            box, _ = self.sandbox('codex')
            box.env.pop('PYTHONPATH')
            box.env['CODEX_HOME'] = str(box.home / 'custom-codex')
            self.write(box.home / 'custom-codex/sessions/2001/02/03/rollout-renamed.jsonl',
                json.dumps({'type': 'session_meta', 'payload': {'id': sid}}) + '\n')
            self.invoke(box, 'codex', sid=sid)


class SharedIndex(unittest.TestCase):
    def test_atomic_entries_are_scoped_and_stale_paths_are_rejected(self):
        from concurrent.futures import ThreadPoolExecutor
        box = layout.Sandbox(self, adapters=('shared',))
        spec = importlib.util.spec_from_file_location('index_helpers', ROOT / 'adapters/shared/session_lookup.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        root = box.home / 'sessions'
        root.mkdir()
        first = root / 'a.jsonl'
        second = root / 'b.jsonl'
        first.touch()
        second.touch()
        with patch.dict(os.environ, box.env):
            index = module.PathIndex('test', [root])
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda i: index.put(str(i % 2), (first, second)[i % 2]), range(32)))
            self.assertEqual(index.get('0'), first)
            self.assertEqual(index.get('1'), second)
            self.assertIsNone(module.PathIndex('test', [box.home / 'other']).get('0'))
            self.assertIsNone(module.PathIndex('other-adapter', [root]).get('0'))
            first.unlink()
            self.assertIsNone(index.get('0'))
            index.key('session:0').write_text(json.dumps(str(box.home / 'sessions/../sessions/b.jsonl')))
            self.assertIsNone(index.get('0'))
            with patch.dict(os.environ, {'ATRIUM_DATA_DIR': str(box.home / 'other-instance')}):
                self.assertIsNone(module.PathIndex('test', [root]).get('1'))


if __name__ == '__main__':
    unittest.main()

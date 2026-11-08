import importlib.util
import json
import os
from pathlib import Path
import subprocess
from concurrent.futures import ThreadPoolExecutor
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'adapters/claude-code'
spec = importlib.util.spec_from_file_location('installed_layout', ROOT / 'tests/installed-layout.py')
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


class SessionLookup(unittest.TestCase):
    def setUp(self):
        self.box = layout.Sandbox(self)
        self.root = self.box.home / '.claude/projects'
        self.root.mkdir(parents=True)
        self.env = self.box.env
        # A recursive search is a regression even when it happens to return
        # the right file. Installed entrypoints must succeed without find.
        stub = self.box.home / 'bin/find'
        stub.write_text('#!/bin/sh\necho recursive-search-forbidden >&2\nexit 99\n')
        stub.chmod(0o755)
        self.script = self.box.script('claude-code', 'extract_session.sh')

    def transcript(self, project, sid='session-123', text='expected prompt'):
        path = self.root / project / (sid + '.jsonl')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'type': 'user', 'sessionId': sid,
            'timestamp': '2026-11-08T00:00:00Z', 'message': {'content': text}}) + '\n')
        return path

    def run_lookup(self, cwd, sid='session-123', code=0):
        result = subprocess.run([str(self.script), '--session-id', sid, '--cwd', cwd,
                                 '--depth', 'quick'], env=self.env, capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, code, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_direct_cwd_never_runs_find(self):
        self.transcript('-work-proj')
        self.assertEqual(self.run_lookup('/work/proj')[0]['title'], 'expected prompt')

    def test_unknown_cwd_finds_exact_filename_without_recursion(self):
        self.transcript('-original-project')
        self.assertEqual(self.run_lookup('/moved/project')[0]['title'], 'expected prompt')

    def test_direct_cwd_wins_over_same_id_elsewhere(self):
        self.transcript('-elsewhere', text='wrong')
        self.transcript('-work-proj')
        self.assertEqual(self.run_lookup('/work/proj')[0]['title'], 'expected prompt')

    def test_entrypoint_from_adapter_working_directory(self):
        self.transcript('-work-proj')
        result = subprocess.run(['bash', 'extract_session.sh', '--session-id', 'session-123',
                                 '--cwd', '/work/proj', '--depth', 'quick'],
                                cwd=self.script.parent, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_custom_config_root(self):
        self.env['CLAUDE_CONFIG_DIR'] = str(self.box.home / 'custom')
        self.root = self.box.home / 'custom/projects'
        self.transcript('-work-proj')
        self.assertEqual(self.run_lookup('/work/proj')[0]['title'], 'expected prompt')

    def test_fixture_id_isolation_and_depths(self):
        fixture = ADAPTER / 'tests/extractor'
        self.env['ATRIUM_TEST_TRANSCRIPT_ROOT'] = str(fixture)
        sid = (fixture / 'fixture-session-id.txt').read_text().strip()
        self.assertEqual(len(self.run_lookup('/tmp', sid)), 2)
        self.run_lookup('/tmp', 'missing', code=1)
        for depth in ('standard', 'deep'):
            result = subprocess.run([str(self.script), '--session-id', sid, '--cwd', '/tmp',
                '--depth', depth], env=self.env, capture_output=True, text=True, check=True)
            self.assertGreater(len(result.stdout.splitlines()), 2)


class IndexLookup(SessionLookup):
    def setUp(self):
        super().setUp()
        spec = importlib.util.spec_from_file_location('session_path', ADAPTER / 'session_path.py')
        self.lookup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.lookup)
        self.environment = patch.dict(os.environ, self.env)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def find(self, cwd='/work/proj', sid='session-123'):
        return self.lookup.find_transcript(self.root, sid, cwd)

    def test_direct_and_cached_hits_never_list_a_directory(self):
        path = self.transcript('-work-proj')
        with patch.object(self.lookup.os, 'scandir', side_effect=AssertionError('directory read')):
            self.assertEqual(self.find(), path)
            self.assertEqual(self.find('/changed/cwd'), path)
        entry = self.lookup._cache_entry(self.root, 'session-123')
        before = entry.stat().st_mtime_ns
        self.find()
        self.assertEqual(entry.stat().st_mtime_ns, before)

    def test_cold_fallback_reads_only_root_and_repairs_moves(self):
        path = self.transcript('-original')
        scandir = os.scandir
        reads = []
        def guarded_scan(directory):
            self.assertEqual(Path(directory), self.root)
            reads.append(directory)
            return scandir(directory)
        with patch.object(self.lookup.os, 'scandir', side_effect=guarded_scan):
            self.assertEqual(self.find(), path)
            self.assertEqual(len(reads), 1)
            path.unlink()
            moved = self.transcript('-moved')
            self.assertEqual(self.find(), moved)
            self.assertEqual(len(reads), 2)
            moved.unlink()
            self.assertIsNone(self.find())
            self.assertFalse(self.lookup._cache_entry(self.root, 'session-123').exists())
            # A miss cannot conceal a newly created transcript.
            self.assertEqual(self.find(), None)
            self.assertEqual(self.find(sid='new-session'), None)
            new = self.transcript('-new', sid='new-session')
            self.assertEqual(self.find(sid='new-session'), new)

    def test_corrupt_and_unwritable_cache_do_not_hide_transcripts(self):
        path = self.transcript('-work-proj')
        self.find()
        entry = self.lookup._cache_entry(self.root, 'session-123')
        for content in ('{broken', 'null', '[]', '"../escape"', '"/absolute"'):
            entry.write_text(content)
            self.assertEqual(self.find('/wrong'), path)
        with patch.object(self.lookup.os, 'replace', side_effect=OSError('read-only cache')):
            entry.unlink()
            self.assertEqual(self.find(), path)
            self.assertEqual(list(entry.parent.iterdir()), [])

    def test_roots_and_instances_are_isolated(self):
        first = self.transcript('-first')
        self.assertEqual(self.find(), first)
        other_root = self.root.parent / 'other-projects'
        self.root = other_root
        second = self.transcript('-second')
        self.assertEqual(self.find(), second)
        self.assertNotEqual(self.lookup._cache_entry(first.parent.parent, 'session-123'),
                            self.lookup._cache_entry(other_root, 'session-123'))
        with patch.dict(os.environ, {'ATRIUM_DATA_DIR': str(self.box.home / 'other-instance')}):
            self.assertEqual(self.find(), second)

    def test_parallel_index_updates_are_atomic(self):
        paths = {f'id-{i}': self.transcript('-work-proj', sid=f'id-{i}') for i in range(12)}
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda sid: self.find(sid=sid), list(paths) * 4))
        self.assertEqual(results, list(paths.values()) * 4)
        with patch.object(self.lookup.os, 'scandir', side_effect=AssertionError('directory read')):
            for sid, path in paths.items():
                self.assertEqual(self.find('/wrong', sid), path)

    def test_path_encoding_agrees_with_claude_session_lister(self):
        for cwd in ('/work/a_b.c space', r'C:\Users\Jane.Doe\repo_name', '/work/你好🚀',
                    '/work/' + 'a' * 220, '/work/' + '🚀' * 110):
            with self.subTest(cwd=cwd):
                path = self.transcript(self.lookup.encode_project(cwd))
                lister = self.box.script('claude-code', 'list_recent_sessions.sh')
                result = subprocess.run([str(lister), cwd], env=self.env, capture_output=True,
                                        text=True, check=True)
                self.assertEqual(json.loads(result.stdout)['sessions'][0]['sourcePath'], str(path))
                with patch.object(self.lookup.os, 'scandir', side_effect=AssertionError('directory read')):
                    self.assertEqual(self.find(cwd), path)

    def test_invalid_session_ids_never_escape_root(self):
        for sid in ('../outside', '/absolute', r'..\outside', '', '..', '*'):
            self.assertIsNone(self.find(sid=sid))


if __name__ == '__main__':
    unittest.main()

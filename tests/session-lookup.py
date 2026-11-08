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
ADAPTERS = ('pi', 'omp', 'antigravity')


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
                if name == 'pi':
                    self.write(home / '.pi/agent/sessions/--work-proj--/2026-11-08T00-00-00-000Z_session-123.jsonl')
                elif name == 'omp':
                    self.write(home / '.omp/agent/sessions/--work-proj--/2026-11-08T00-00-00-000Z_session-123.jsonl')
                elif name == 'antigravity':
                    self.write(home / '.antigravity/brain/session-123/.system_generated/logs/transcript.jsonl')
                elif name == 'codex':
                    path = self.write(home / '.codex/sessions/2026/11/08/rollout-exact.jsonl')
                    with sqlite3.connect(home / '.codex/state_5.sqlite') as conn:
                        conn.execute('create table threads (id text primary key, rollout_path text)')
                        conn.execute('insert into threads values (?, ?)', ('session-123', str(path)))
                else:
                    self.write(home / '.local/share/opencode/project/hash/storage/session/info/ses_session-123.json', '{"id":"session-123"}')
                self.invoke(box, name)
                self.assertFalse(marker.exists())

    def test_missing_never_recurses(self):
        for name in ADAPTERS:
            with self.subTest(adapter=name):
                box, marker = self.sandbox(name)
                for root in ('.pi/agent/sessions', '.omp/agent/sessions', '.codex/sessions',
                             '.gemini/antigravity-cli', '.local/share/opencode'):
                    (box.home / root).mkdir(parents=True)
                self.invoke(box, name, expected=1)
                self.assertFalse(marker.exists())

    def test_antigravity_never_lists_and_does_not_prefix_match(self):
        box, _ = self.sandbox('antigravity')
        spec = importlib.util.spec_from_file_location('agy_paths', ROOT / 'adapters/antigravity/session_path.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        path = self.write(box.home / '.gemini/antigravity-cli/brain/session-123/.system_generated/logs/transcript.jsonl')
        with patch.dict(os.environ, box.env), patch('os.scandir', side_effect=AssertionError('tree scan')):
            self.assertEqual(module.find_transcript('session-123'), path)
            self.assertIsNone(module.find_transcript('session'))
            self.assertIsNone(module.find_transcript('../session-123'))
            path.unlink()
            self.assertIsNone(module.find_transcript('session-123'))


class TimestampIndex(InstalledLookup):
    def test_cache_and_directory_refresh_without_other_projects(self):
        for name in [a for a in ADAPTERS if a in ('pi', 'omp')]:
            with self.subTest(adapter=name):
                box, _ = self.sandbox(name)
                root = box.home / ('.' + name) / 'agent/sessions'
                directory = root / '--work-proj--'
                path = self.write(directory / '2026-11-08T00-00-00-000Z_session-123.jsonl')
                self.write(root / 'unrelated/deep/tree/other.jsonl')
                spec = importlib.util.spec_from_file_location(name + '_paths', ROOT / 'adapters' / name / 'session_path.py')
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                scandir = os.scandir
                reads = []
                def only_cwd(folder):
                    self.assertEqual(Path(folder), directory)
                    reads.append(str(folder))
                    return scandir(folder)
                with patch.dict(os.environ, box.env), patch('os.scandir', side_effect=only_cwd):
                    self.assertEqual(module.find_transcript('session-123', '/work/proj'), path)
                    self.assertEqual(len(reads), 1)
                    if name == 'omp':
                        with patch.object(module, 'encoded_cwds', side_effect=AssertionError('cache hit encoded cwd')):
                            self.assertEqual(module.find_transcript('session-123', '/changed'), path)
                    else:
                        self.assertEqual(module.find_transcript('session-123', '/changed'), path)
                    self.assertIsNone(module.find_transcript('missing', '/work/proj'))
                    self.assertEqual(len(reads), 1)
                    new = self.write(directory / '2026-11-09T00-00-00-000Z_new.jsonl')
                    self.assertEqual(module.find_transcript('new', '/work/proj'), new)
                    self.assertEqual(len(reads), 2)
                    path.unlink()
                    self.assertIsNone(module.find_transcript('session-123', '/work/proj'))
                    self.assertEqual(len(reads), 3)

    def test_override_flat_directory_and_exact_suffix(self):
        for name in [a for a in ADAPTERS if a in ('pi', 'omp')]:
            with self.subTest(adapter=name):
                box, _ = self.sandbox(name)
                root = box.home / 'custom sessions'
                box.env[name.upper() + '_CODING_AGENT_SESSION_DIR'] = str(root)
                self.write(root / '2026-11-08T00-00-00-000Z_not-session-123.jsonl')
                self.invoke(box, name, expected=1)
                self.write(root / '2026-11-08T00-00-00-000Z_session-123.jsonl')
                self.invoke(box, name)

    def test_omp_home_relative_and_hashed_directories(self):
        box, _ = self.sandbox('omp')
        root = box.home / '.omp/agent/sessions'
        cwd = str(box.home / 'work/my_repo')
        self.write(root / '-work-my_repo/2026-11-08T00-00-00-000Z_session-123.jsonl')
        self.invoke(box, 'omp', cwd=cwd)
        import hashlib
        digest = hashlib.sha256(os.path.realpath(cwd).encode()).hexdigest()
        self.write(root / ('home-my_repo-' + digest) / '2026-11-08T00-00-00-000Z_hashed.jsonl')
        self.invoke(box, 'omp', sid='hashed', cwd=cwd)

    def test_cache_corruption_and_unwritable_cache(self):
        box, _ = self.sandbox('pi')
        root = box.home / '.pi/agent/sessions'
        self.write(root / '--work-proj--/2026-11-08T00-00-00-000Z_session-123.jsonl')
        self.invoke(box, 'pi')
        cache = box.data_dirs[0] / 'cache/session-paths-v1/pi'
        for path in cache.iterdir():
            path.write_text('null')
        self.invoke(box, 'pi')
        box.env['ATRIUM_DATA_DIR'] = str(self.write(box.home / 'not-a-directory'))
        self.invoke(box, 'pi')


if __name__ == '__main__':
    unittest.main()

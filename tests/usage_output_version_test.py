import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('usage_output', Path(__file__).resolve().parents[1] / 'scripts/usage-output-version.py')
usage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(usage)
PROGRAM = '''import json
import sys
from pathlib import Path
USAGE_OUTPUT_VERSION = 1
sys.path.insert(0, str(Path(__file__).parent.parent / 'shared'))
from semantic_value import NUMBER
for line in sys.stdin:
    request = json.loads(line)
    for item in map(json.loads, Path(request['path']).read_text().splitlines()):
        print(json.dumps(dict(type='usage', dedupe=item['id'], session_id='invented',
                             fork_of=None, model='invented-model', at='2026-01-01T00:00:00.000Z',
                             tokens=dict(input=NUMBER, output=1), cost_usd=None)))
    print(json.dumps(dict(type='checkpoint', path=request['path'], complete=True)))
'''


class SemanticVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='usage-output-selftest-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.adapter = self.root / 'adapters/invented'
        self.fixtures = self.adapter / 'tests/extractor/usage'
        self.shared = self.root / 'adapters/shared'
        self.fixtures.mkdir(parents=True)
        self.shared.mkdir()
        self.script = self.adapter / 'extract_session_usage.py'
        self.script.write_text(PROGRAM)
        self.value = self.shared / 'semantic_value.py'
        self.value.write_text('NUMBER = 10\n')
        launcher = self.adapter / 'extract_session.sh'
        launcher.write_text('#!/usr/bin/env bash\nset -eu\nexec python3 "$(dirname "$0")/extract_session_usage.py" "$@"\n')
        launcher.chmod(0o755)
        (self.fixtures / 'native.jsonl').write_text('{"id":"invented-request"}\n')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Synthetic Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        usage.check(self.adapter, record=True)
        self.commit()

    def git(self, *args):
        env = {key:value for key,value in os.environ.items() if not key.startswith('GIT_')}
        return subprocess.run(['git', '-C', str(self.root), *args], env=env, capture_output=True, check=True)

    def commit(self):
        self.git('add', '--all')
        self.git('commit', '-qm', 'synthetic fixture state')

    def bump(self):
        self.script.write_text(self.script.read_text().replace('USAGE_OUTPUT_VERSION = 1', 'USAGE_OUTPUT_VERSION = 2'))

    def test_output_change_without_bump_is_rejected_even_if_rerecorded(self):
        self.value.write_text('NUMBER = 20\n')
        with self.assertRaisesRegex(ValueError, 'bump USAGE_OUTPUT_VERSION'):
            usage.check(self.adapter, record=True)
        self.bump()
        with self.assertRaisesRegex(ValueError, 'versions above 1 need app-side reconciliation'):
            usage.check(self.adapter, record=True)

    def test_bump_without_output_witness_is_rejected(self):
        records = json.loads((self.adapter / usage.GOLDEN).read_text())['records']
        with self.assertRaisesRegex(ValueError, 'a bump must change fixture output'):
            usage.transition(2, records, 1, records)

    def test_publisher_blocks_any_version_above_one(self):
        self.bump()
        with self.assertRaisesRegex(ValueError, 'versions above 1 need app-side reconciliation'):
            usage.check(self.adapter, record=True)

    def test_fixture_only_addition_does_not_require_a_bump(self):
        (self.fixtures / 'another.jsonl').write_text('{"id":"another-invented-request"}\n')
        usage.check(self.adapter, record=True)
        self.commit()
        (self.root / 'metadata.txt').write_text('synthetic metadata-only follow-up\n')
        self.commit()
        usage.check(self.adapter)

    def test_metadata_commit_does_not_hide_a_missed_bump(self):
        self.value.write_text('NUMBER = 20\n')
        with self.assertRaises(ValueError):
            usage.check(self.adapter, record=True)
        self.commit()
        (self.root / 'metadata.txt').write_text('synthetic metadata-only follow-up\n')
        self.commit()
        with self.assertRaisesRegex(ValueError, 'bump USAGE_OUTPUT_VERSION'):
            usage.check(self.adapter)
        with self.assertRaisesRegex(ValueError, 'bump USAGE_OUTPUT_VERSION'):
            usage.check(self.adapter, record=True)

    def test_diagnostics_and_shared_runtime_refactors_do_not_require_a_bump(self):
        self.value.write_text('# same invented semantics\nNUMBER = 5 + 5\n')
        self.script.write_text(self.script.read_text().replace("complete=True", "complete=True, diagnostic='invented note'"))
        self.script.write_text(self.script.read_text().replace("cost_usd=None", "cost_usd=None, diagnostic='ignored'"))
        usage.check(self.adapter)

    def new_shape(self, action):
        old = PROGRAM.replace("        print(json.dumps(dict(type='usage'", "        if item.get('shape') == 'new':\n            " + action + "\n        print(json.dumps(dict(type='usage'")
        self.script.write_text(old)
        usage.check(self.adapter, record=True)
        self.commit()
        (self.fixtures / 'new.jsonl').write_text('{"id":"invented-new-shape","shape":"new"}\n')
        self.script.write_text(PROGRAM)
        with self.assertRaisesRegex(ValueError, 'bump USAGE_OUTPUT_VERSION'):
            usage.check(self.adapter, record=True)
        self.bump()
        with self.assertRaisesRegex(ValueError, 'versions above 1 need app-side reconciliation'):
            usage.check(self.adapter, record=True)

    def test_previous_extractor_error_on_new_shape_requires_a_bump(self):
        self.new_shape('raise ValueError("invented unsupported shape")')

    def test_previous_extractor_skip_on_new_shape_requires_a_bump(self):
        self.new_shape('continue')

    def test_index_snapshot_cannot_borrow_unstaged_version_and_golden(self):
        self.value.write_text('NUMBER = 20\n')
        self.bump()
        golden = json.loads((self.adapter / usage.GOLDEN).read_text())
        golden['version'] = 2
        golden['records'][0]['tokens']['input'] = 20
        golden['sha256'] = usage.fingerprint(golden['records'])
        (self.adapter / usage.GOLDEN).write_text(json.dumps(golden) + '\n')
        self.git('add', '--', 'adapters/shared/semantic_value.py')
        with tempfile.TemporaryDirectory(prefix='usage-staged-selftest-') as temporary:
            mirror = Path(temporary)
            self.git('checkout-index', '--all', '--prefix=' + str(mirror) + '/')
            with self.assertRaisesRegex(ValueError, 'bump USAGE_OUTPUT_VERSION'):
                usage.check(mirror / 'adapters/invented', repository=self.root)

    def test_record_writes_one_consistent_version_hash_pair(self):
        data = json.loads((self.adapter / usage.GOLDEN).read_text())
        self.assertEqual(data['version'], 1)
        self.assertEqual(data['sha256'], usage.fingerprint(data['records']))
        self.assertEqual(data['records'][0]['tokens']['input'], 10)


if __name__ == '__main__':
    unittest.main()

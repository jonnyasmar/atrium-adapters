import json
from pathlib import Path
import sys
import tempfile
import unittest

ADAPTER = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).parent
sys.path.insert(0, str(ADAPTER.parent / 'shared'))
from extract_session_usage_test import run_batch
from extract_session_usage import fold


def invented(name):
    rows = [json.loads(line) for line in (FIXTURES / 'input' / name).read_text().splitlines()]
    rows[0]['payload'].pop('subagent_history_start_ordinal', None)
    rows[0]['payload']['history_mode'] = 'paginated'
    return rows


def write(path, rows):
    path.write_text(''.join(json.dumps(row) + '\n' for row in rows))


class ForkPrefixTests(unittest.TestCase):
    def test_parent_siblings_and_grandchild_dedupe_in_either_scan_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for name in ('root.jsonl', 'child-a.jsonl', 'child-b.jsonl', 'grandchild.jsonl'):
                path = root / name
                write(path, invented(name))
                paths.append(dict(path=str(path)))
            expected = [json.loads(line) for line in (FIXTURES / 'expected-merged.jsonl').read_text().splitlines()]
            for requests in (paths, list(reversed(paths))):
                output = run_batch(ADAPTER, requests, root)
                merged = {}
                for event in output:
                    if event['type'] == 'usage':
                        merged[event['dedupe']] = fold(merged.get(event['dedupe']), event)
                    else:
                        self.assertTrue(event['complete'])
                self.assertEqual([merged[key] for key in sorted(merged)], expected)

    def test_prefix_ownership_does_not_require_ordinals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('root.jsonl', 'child-a.jsonl'):
                rows = invented(name)
                for row in rows:
                    row.pop('ordinal', None)
                write(root / name, rows)
            output = run_batch(ADAPTER, [dict(path=str(root / 'child-a.jsonl'))], root)
            self.assertEqual([row['dedupe'] for row in output[:-1]], ['root:105', 'child-a:214'])
            self.assertTrue(output[-1]['complete'])

    def test_absent_parent_keeps_checkpoint_then_same_child_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'child-a.jsonl'
            rows = invented('child-a.jsonl')
            write(path, rows[:2])
            request = dict(path=str(path))
            token = run_batch(ADAPTER, [request], root)[-1]['resume']
            write(path, rows)
            request['resume'] = token
            missing = run_batch(ADAPTER, [request], root)
            self.assertEqual(len(missing), 1)
            self.assertFalse(missing[-1]['complete'])
            self.assertEqual(missing[-1]['resume'], token)
            self.assertEqual(missing[-1]['error'], 'fork-ancestry-unavailable:2')
            self.assertEqual(missing[-1]['malformed'], 2)
            write(root / 'root.jsonl', invented('root.jsonl'))
            recovered = run_batch(ADAPTER, [request], root)
            self.assertEqual([row['dedupe'] for row in recovered[:-1]], ['root:105', 'child-a:214'])
            self.assertTrue(recovered[-1]['complete'])
            replay = run_batch(ADAPTER, [dict(request, resume=recovered[-1]['resume'])], root)
            self.assertEqual(len(replay), 1)
            self.assertTrue(replay[-1]['complete'])

    def test_equal_cumulative_totals_with_different_last_usage_end_the_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root / 'root.jsonl', invented('root.jsonl'))
            rows = invented('child-a.jsonl')
            rows[2]['payload']['info']['last_token_usage']['cached_input_tokens'] += 1
            path = root / 'child-a.jsonl'
            write(path, rows)
            output = run_batch(ADAPTER, [dict(path=str(path))], root)
            self.assertEqual([row['session_id'] for row in output[:-1]], ['child-a', 'child-a'])


if __name__ == '__main__':
    unittest.main()

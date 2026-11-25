import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ADAPTER = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('grok_usage', ADAPTER / 'extract_session_usage.py')
grok = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(ADAPTER))
spec.loader.exec_module(grok)
import extract_session_usage as shared


def turn(prompt='p'):
    return dict(timestamp=1794000100, method='_x.ai/session/update',
                params=dict(sessionId='invented-session', update=dict(sessionUpdate='turn_completed', prompt_id=prompt,
                usage=dict(modelUsage={'invented-model': dict(inputTokens=1000, outputTokens=80,
                    cachedReadTokens=700, cacheCreationTokens=100, reasoningTokens=20, costUsdTicks=1230000000)}))))


class LegacyTests(unittest.TestCase):
    def test_inclusive_tokens_cost_ticks_and_duplicate_turns(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'updates.jsonl'
            source.write_text((json.dumps(turn())+'\n') * 2)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                shared.extract(dict(path=str(source)), grok.GrokUsage)
            rows = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]['tokens'], dict(input=200, output=80, cache_read=700,
                cache_write_5m=100, cache_write_1h=0, reasoning=20))
            self.assertEqual(rows[0]['cost_usd'], 0.123)

    def test_scale_one_appended_turn_does_not_replay_10x_100x_sessions_or_history(self):
        work = []
        for size in (10, 100, 1000):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for number in range(size):
                    (root / f'cold-{number}.jsonl').write_text('{}\n')
                source = root / 'updates.jsonl'
                source.write_text('{}\n' * size)
                def extract(resume=None):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        shared.extract(dict(path=str(source), resume=resume), grok.GrokUsage)
                    return [json.loads(line) for line in output.getvalue().splitlines()]
                cursor = extract()[-1]['resume']
                with source.open('a') as stream:
                    stream.write(json.dumps(turn())+'\n')
                original = grok.GrokUsage.event
                calls = []
                def observed(parser, row):
                    calls.append(1)
                    return original(parser, row)
                with patch.object(grok.GrokUsage, 'event', observed), patch.object(
                    grok.GrokUsage, 'restore_context', side_effect=AssertionError('history replay')):
                    result = extract(cursor)
                work.append(len(calls))
                self.assertEqual(result[-1]['events'], 1)
                self.assertLess(len(result[-1]['resume']), 256)
        self.assertEqual(work, [1, 1, 1])


if __name__ == '__main__':
    unittest.main()

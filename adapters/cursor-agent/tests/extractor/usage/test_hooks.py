import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ADAPTER = Path(__file__).resolve().parents[3]


class UsageHookTests(unittest.TestCase):
    def test_usage_without_counters_does_not_spawn_the_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli, output = root / 'atrium', root / 'called'
            cli.write_text('#!/bin/sh\ntouch "$HOOK_TEST_OUTPUT"\n')
            cli.chmod(0o700)
            env = dict(os.environ, ATRIUM_CLI_PATH=str(cli), ATRIUM_PANE_ID='pane',
                       HOOK_TEST_OUTPUT=str(output))
            subprocess.run(['bash', str(ADAPTER / 'cursor-hook-entry.sh'), 'usage-update'],
                           input='{"conversation_id":"s"}', text=True, env=env, check=True)
            self.assertFalse(output.exists())

    def test_chat_usage_is_whitelisted_while_activity_stays_suppressed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / 'atrium'
            output = root / 'captured.json'
            cli.write_text('#!/bin/sh\ncat > "$HOOK_TEST_OUTPUT"\n')
            cli.chmod(0o700)
            env = dict(os.environ, ATRIUM_CLI_PATH=str(cli), ATRIUM_PANE_ID='invented-pane',
                       ATRIUM_CHAT_SDK_HOOKS='1', HOOK_TEST_OUTPUT=str(output))
            payload = dict(conversation_id='invented-session', generation_id='invented-generation',
                           model='invented-model', input_tokens=100, output_tokens=20,
                           cache_read_tokens=50, cache_write_tokens=10, text='never persist this')
            subprocess.run(['bash', str(ADAPTER / 'cursor-hook-entry.sh'), 'usage-update'],
                           input=json.dumps(payload), text=True, env=env, check=True)
            result = json.loads(output.read_text())
            self.assertEqual(result['session_id'], 'invented-session')
            self.assertEqual(result['input_tokens'], 100)
            self.assertNotIn('text', result)
            self.assertNotIn('conversation_id', result)
            output.unlink()
            subprocess.run(['bash', str(ADAPTER / 'cursor-hook-entry.sh'), 'stop'],
                           input=json.dumps(payload), text=True, env=env, check=True)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()

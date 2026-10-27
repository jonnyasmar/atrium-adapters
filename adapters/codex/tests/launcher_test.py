import json
from pathlib import Path
import subprocess
import unittest


ADAPTER = Path(__file__).resolve().parents[1]


class CodexLauncherTests(unittest.TestCase):
    def command(self, flags, session=None):
        script = "build_launch_command.sh" if session is None else "build_resume_command.sh"
        args = [] if session is None else [session]
        result = subprocess.run(
            ["bash", str(ADAPTER / script), *args, json.dumps(flags)],
            check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)["command"]

    def test_literal_profile_arguments_survive_launch_and_resume(self):
        values = [
            'developer_instructions="any text with spaces"',
            'model_instructions_file="C:\\my folder\\notes.md"',
            "it's $(echo nope); * [abc]",
            "line one\nline two\tend",
            "",
        ]
        for value in values:
            for session in [None, "session 'one' [1m]"]:
                with self.subTest(value=value, session=session):
                    command = self.command({
                        "extraArgs": "--legacy-must-not-be-duplicated",
                        "extraArgv": ["-c", value],
                    }, session)
                    expected = ["codex", "-c", value]
                    if session is not None:
                        expected += ["resume", session]
                    self.assertEqual(command, expected)

    def test_legacy_flags_keep_their_whitespace_split_without_globbing(self):
        self.assertEqual(
            self.command({"extraArgs": '-c developer_instructions="single" --search *'}),
            ["codex", "-c", 'developer_instructions="single"', "--search", "*"],
        )

    def test_launcher_knobs_remain_literal_and_resume_matches_launch(self):
        flags = {"model": 'model "quoted"', "effort": "high", "fast": True,
                 "dangerouslySkipPermissions": True}
        expected = ["codex", "--dangerously-bypass-approvals-and-sandbox",
                    "-m", 'model "quoted"', "-c", 'model_reasoning_effort="high"',
                    "--enable", "fast_mode", "-c", 'service_tier="fast"']
        self.assertEqual(self.command(flags), expected)
        self.assertEqual(self.command(flags, "session"), expected + ["resume", "session"])

    def test_empty_structured_arguments_override_legacy(self):
        self.assertEqual(self.command({"extraArgv": [], "extraArgs": "--search"}), ["codex"])


if __name__ == "__main__":
    unittest.main()

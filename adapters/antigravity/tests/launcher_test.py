import json
from pathlib import Path
import subprocess
import unittest


ADAPTER = Path(__file__).resolve().parents[1]


class AntigravityLauncherTests(unittest.TestCase):
    def test_terminal_yolo_launch_and_resume(self):
        for resume in (False, True):
            for bypass in (False, True):
                with self.subTest(resume=resume, bypass=bypass):
                    flags = json.dumps({
                        "dangerouslySkipPermissions": bypass,
                        "model": "gemini-4-neon-high",
                    })
                    script = "build_resume_command.sh" if resume else "build_launch_command.sh"
                    args = ["saved-session", flags] if resume else [flags]
                    command = json.loads(subprocess.check_output(
                        ["bash", str(ADAPTER / script), *args], text=True,
                    ))["command"]
                    expected = ["env", "AGY_CLI_DISABLE_AUTO_UPDATE=true", "agy"]
                    if resume:
                        expected += ["--conversation", "saved-session"]
                    if bypass:
                        expected += ["--dangerously-skip-permissions"]
                    expected += ["--model", "gemini-4-neon-high"]
                    self.assertEqual(command, expected)

    def test_description_distinguishes_terminal_from_chat(self):
        options = json.loads((ADAPTER / "launcher_options.json").read_text())["options"]
        description = next(o for o in options if o["key"] == "dangerouslySkipPermissions")["description"]
        self.assertIn("Terminal: --dangerously-skip-permissions", description)
        self.assertIn("chat: atrium auto-approves tool permission requests", description)

    def test_neon_catalog(self):
        # Vendor model guide, 2026-11-18: https://antigravity.google/docs/models
        options = json.loads((ADAPTER / "launcher_options.json").read_text())["options"]
        models = next(o for o in options if o["key"] == "model")["choices"]
        for effort in ("low", "medium", "high", "xhigh"):
            self.assertIn(f"gemini-4-neon-{effort}", models)
        self.assertIn("gemini-4-argon-high", models)


if __name__ == "__main__":
    unittest.main()

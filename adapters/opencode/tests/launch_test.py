import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from jsonschema import Draft202012Validator


ADAPTER = Path(__file__).resolve().parents[1]
ROOT = ADAPTER.parents[1]
WRAPPER = str(ADAPTER / "opencode-with-variant.sh")
HEAD = ["env", "OPENCODE_DISABLE_AUTOUPDATE=1"]


def run(script, *args):
    result = subprocess.run(
        ["bash", str(ADAPTER / script), *args],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)["command"]


def launch(flags):
    return run("build_launch_command.sh", flags if isinstance(flags, str) else json.dumps(flags))


def resume(session_id, flags):
    return run("build_resume_command.sh", session_id, json.dumps(flags))


class LaunchCommandTests(unittest.TestCase):
    def test_launcher_schema_and_effort_vocabulary(self):
        launcher = json.loads((ADAPTER / "launcher_options.json").read_text())
        schema = json.loads((ROOT / "schemas/methods/launcher_options.schema.json").read_text())
        Draft202012Validator(schema).validate(launcher)
        effort = {row["key"]: row for row in launcher["options"]}["effort"]
        # Every variant key `opencode models --verbose` reported across its
        # 724-model catalog (opencode 1.19.0, 2026-10-12). "" = the model's own
        # default variant.
        self.assertEqual(effort["choices"], ["none", "minimal", "low", "medium", "high", "xhigh", "max"])
        self.assertEqual(effort["default"], "")

    def test_flags_without_effort_keep_the_bare_binary(self):
        cases = [
            ({}, []),
            ({"autoApprove": True}, ["--auto"]),
            ({"permissionMode": "auto"}, ["--auto"]),
            ({"model": "opencode/big-pickle"}, ["--model", "opencode/big-pickle"]),
            (
                {"model": "openrouter/apodex/apodex-1.1-mini:free", "agent": "plan",
                 "extraArgs": "--log-level DEBUG  --pure"},
                ["--model", "openrouter/apodex/apodex-1.1-mini:free", "--agent", "plan",
                 "--log-level", "DEBUG", "--pure"],
            ),
            ({"autoApprove": False, "model": "", "agent": "", "extraArgs": ""}, []),
            ({"model": 'quote"model'}, ["--model", 'quote"model']),
        ]
        for flags, tail in cases:
            with self.subTest(flags=flags):
                self.assertEqual(launch(flags), HEAD + ["opencode"] + tail)

    def test_malformed_flags_fall_back_to_a_bare_launch(self):
        for flags in ("not json", "[]", '"string"'):
            with self.subTest(flags=flags):
                self.assertEqual(launch(flags), HEAD + ["opencode"])

    def test_effort_with_model_routes_through_the_variant_wrapper(self):
        self.assertEqual(
            launch({"model": "opencode/muse-spark-1.3-contributor-free", "effort": "high",
                    "agent": "plan", "autoApprove": True}),
            HEAD + ["ATRIUM_OPENCODE_VARIANT=high", WRAPPER, "--auto",
                    "--model", "opencode/muse-spark-1.3-contributor-free", "--agent", "plan"],
        )

    def test_effort_needs_a_model_and_a_shell_safe_token(self):
        for flags in (
            {"effort": "high"},
            {"effort": "", "model": "a/b"},
            {"effort": "hi gh", "model": "a/b"},
            {"effort": "high;rm", "model": "a/b"},
            {"effort": 3, "model": "a/b"},
        ):
            with self.subTest(flags=flags):
                self.assertNotIn(WRAPPER, launch(flags))
                self.assertIn("opencode", launch(flags))

    def test_resume_mirrors_launch(self):
        self.assertEqual(
            resume('ses_"1', {"model": "opencode/x", "agent": "plan", "extraArgs": "--pure"}),
            ["OPENCODE_DISABLE_AUTOUPDATE=1", "opencode", "--session", 'ses_"1',
             "--model", "opencode/x", "--agent", "plan", "--pure"],
        )
        self.assertEqual(
            resume("ses_1", {"model": "opencode/x", "effort": "low"}),
            ["OPENCODE_DISABLE_AUTOUPDATE=1", "ATRIUM_OPENCODE_VARIANT=low", WRAPPER,
             "--session", "ses_1", "--model", "opencode/x"],
        )


class VariantWrapperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        stub = Path(cls.tmp.name) / "opencode"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            "jq -nc --arg args \"$*\" --arg cfg \"${OPENCODE_CONFIG_CONTENT-}\" "
            "--arg leak \"${ATRIUM_OPENCODE_VARIANT-}\" '{$args, $cfg, $leak}'\n"
        )
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        cls.path = f"{cls.tmp.name}{os.pathsep}{os.environ['PATH']}"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def wrap(self, *args, variant="high", config=None):
        env = {**os.environ, "PATH": self.path, "ATRIUM_OPENCODE_VARIANT": variant}
        env.pop("OPENCODE_CONFIG_CONTENT", None)
        if config is not None:
            env["OPENCODE_CONFIG_CONTENT"] = config
        result = subprocess.run(
            ["bash", WRAPPER, *args], env=env, check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)

    def test_sets_the_launch_agent_model_and_variant(self):
        out = self.wrap("--model", "opencode/m")
        self.assertEqual(out["args"], "--model opencode/m")
        self.assertEqual(json.loads(out["cfg"]),
                         {"agent": {"build": {"model": "opencode/m", "variant": "high"}}})
        self.assertEqual(out["leak"], "")

    def test_merges_into_an_existing_pane_config(self):
        existing = {"provider": {"atrium_x": {"name": "X"}}, "agent": {"plan": {"temperature": 0.1}}}
        out = self.wrap("-m", "a/b", "--agent=plan", variant="max", config=json.dumps(existing))
        self.assertEqual(json.loads(out["cfg"]), {
            "provider": {"atrium_x": {"name": "X"}},
            "agent": {"plan": {"temperature": 0.1, "model": "a/b", "variant": "max"}},
        })

    def test_leaves_unusable_inputs_alone(self):
        self.assertEqual(self.wrap("--model", "a/b", config="not json")["cfg"], "not json")
        self.assertEqual(self.wrap("--model", "a/b", config="[]")["cfg"], "[]")
        self.assertEqual(self.wrap("--session", "s")["cfg"], "")
        self.assertEqual(self.wrap("--model", "a/b", variant="")["cfg"], "")
        self.assertEqual(self.wrap()["args"], "")


if __name__ == "__main__":
    unittest.main()

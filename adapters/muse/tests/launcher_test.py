import json
from pathlib import Path
import subprocess
import unittest

from jsonschema import Draft202012Validator


ADAPTER = Path(__file__).resolve().parents[1]
ROOT = ADAPTER.parents[1]


class WonderLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.launcher = json.loads((ADAPTER / "launcher_options.json").read_text())
        # model/list captured from Muse Code 1.4.6 after session/start, 2026-10-12.
        cls.catalog = json.loads((ADAPTER / "tests/model-list.json").read_text())
        cls.wonder = cls.catalog["models"][0]
        cls.options = {row["key"]: row for row in cls.launcher["options"]}

    def test_wonder_matches_account_catalog(self):
        self.assertEqual(self.catalog["source"], "providerCatalog")
        choices = self.options["model"]["choices"]
        self.assertEqual(choices[0]["value"], self.wonder["modelId"])
        self.assertEqual(choices[0]["label"], "Muse Wonder")
        self.assertEqual(choices[0]["efforts"], self.wonder["variants"])
        self.assertTrue(set(choices[0]["efforts"]) <= set(self.options["effort"]["choices"]))
        self.assertEqual(self.options["effort"]["default"], self.wonder["defaultReasoningEffort"])
        self.assertNotIn("muse-wonder", [choice["value"] for choice in choices])

    def test_efforts_follow_model_family(self):
        models = {row["modelId"]: row for row in self.catalog["models"]}
        for choice in self.options["model"]["choices"]:
            model_id = choice["value"].removesuffix("-contributor")
            with self.subTest(model=choice["value"]):
                self.assertEqual(choice["efforts"], models[model_id]["variants"])
        self.assertEqual(self.options["effort"]["choices"], self.wonder["variants"])

    def test_launcher_schema(self):
        schema = json.loads((ROOT / "schemas/methods/launcher_options.schema.json").read_text())
        Draft202012Validator(schema).validate(self.launcher)

    def test_wonder_launch_and_resume(self):
        for effort in self.wonder["variants"]:
            flags = json.dumps({"model": self.wonder["modelId"], "effort": effort})
            for session_id in (None, "019f1111-2222-7333-8444-555555555555", ""):
                with self.subTest(effort=effort, session_id=session_id):
                    if session_id is None:
                        script = "build_launch_command.sh"
                        args = [flags]
                        prefix = ["muse"]
                    else:
                        script = "build_resume_command.sh"
                        args = [session_id, flags]
                        prefix = ["muse", "resume", session_id or "--last"]
                    result = subprocess.run(
                        ["bash", str(ADAPTER / script), *args],
                        check=True, capture_output=True, text=True,
                    )
                    self.assertEqual(
                        json.loads(result.stdout)["command"],
                        prefix + ["--model", self.wonder["modelId"], "--reasoning-effort", effort],
                    )


if __name__ == "__main__":
    unittest.main()

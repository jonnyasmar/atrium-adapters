"""Canonical assets atrium pushes to every install.

Two checks:

- Every listed sha256 matches the file on disk. atrium refuses an asset whose
  bytes don't match its digest, and one stale digest skips the whole refresh
  with only a warning, so an edit that forgets the digest silently never ships.
- `atrium-context.md` stays within its budget. It is the base rules every agent
  receives at session start; on adapters that inject the whole manifest in one
  hook it shares Claude Code's ~10,000-character cap with the agent and skills
  sections, so growth has to be a decision, not drift.
"""

import hashlib
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTEXT_CHAR_CAP = 4_800


class CanonicalAssetTests(unittest.TestCase):
    def test_every_digest_matches_its_file(self):
        manifest = json.loads((ROOT / "canonical-assets.json").read_text())
        for asset in manifest["assets"]:
            with self.subTest(asset=asset["id"]):
                body = (ROOT / asset["remotePath"]).read_bytes()
                self.assertEqual(
                    hashlib.sha256(body).hexdigest(),
                    asset["sha256"],
                    f"refresh the sha256 for {asset['remotePath']}",
                )

    def test_base_context_stays_within_its_budget(self):
        text = (ROOT / "adapters/shared/atrium-context.md").read_text(encoding="utf-8")
        self.assertLessEqual(
            len(text),
            CONTEXT_CHAR_CAP,
            f"atrium-context.md is {len(text)} characters; the cap is {CONTEXT_CHAR_CAP}",
        )


if __name__ == "__main__":
    unittest.main()

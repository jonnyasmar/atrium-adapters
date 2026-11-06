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

class DirectorDashboardRules(unittest.TestCase):
    def test_relocated_dashboard_rules_keep_every_fact(self):
        reference = (ROOT / "skills/atrium/references/hq.md").read_text()
        self.assertIn('Your dashboard and dock\n- Your dashboard is canvas note {note}, in your dock\'s Overview alongside live blocks: Chats (your main chat and side chats), Work (every delegation, with its worker, state and age), Browser (your browsers and any hand-off waiting), Routines (the next runs) and Attached (panes and notes on your dock). Each row shows its live state (needs you, working, done, failed), so never repeat those items, their states or counts of them ("4 delegations done"), and drop blocks that do at your next update. The board is for what only you know: questions waiting on the owner, decisions, context, notes. Make it glanceable and visual, as the skill\'s `references/dashboard-design.md` shows. Update it as those change, never every turn (`atrium note canvas-patch` a section, `atrium note write` all of it), then look at it: `atrium note preview`.\n- To show the owner another pane or note, attach it to your `atrium-dock` (read it with `atrium agent definition show {slug}`, save it with `atrium agent definition save {slug} --metadata \'atrium-dock=<json>\'`), keeping what\'s there.', reference)

if __name__ == "__main__":
    unittest.main()

"""Run adapter entrypoints from the layout atrium installs, not the repo.

atrium activates every adapter, and the shared runtime, as a relative directory
symlink: <data>/adapters/<name> -> .managed/<name>/generations/<key>. The
kernel resolves `..` through that link physically, so a script that reaches
for "$(dirname "$0")/../shared" lands in .managed/<name>/generations/ and finds
nothing. In the repo, adapters/shared really is a sibling, which is why the
source-tree tests passed while every install failed.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = ROOT / "adapters"
GENERATION = f"{'a' * 64}-{'b' * 40}"


def install_like_atrium(data_dir, names):
    """Mirror atrium's managed activation: a copied generation plus a relative link."""
    adapters = data_dir / "adapters"
    for name in names:
        generation = adapters / ".managed" / name / "generations" / GENERATION
        shutil.copytree(ADAPTERS / name, generation, ignore=shutil.ignore_patterns("tests"))
        (adapters / name).symlink_to(
            Path(".managed") / name / "generations" / GENERATION, target_is_directory=True
        )


def isolated_env(home, data_dir):
    """A clean environment so no real HOME, atrium instance or CLI is touched."""
    tools = home / "bin"
    tools.mkdir()
    for binary in ("claude", "codex"):
        stub = tools / binary
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o755)
    for tool in ("jq", "perl", "python3"):
        found = shutil.which(tool)
        if found:
            (tools / tool).symlink_to(found)
    return {
        "HOME": str(home),
        "PATH": f"{tools}:/usr/bin:/bin",
        "LANG": "C",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "ATRIUM_DATA_DIR": str(data_dir),
    }


def run(script, *args, env, stdin=None):
    result = subprocess.run(
        [str(script), *args], env=env, input=stdin, capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        raise AssertionError(
            f"{script} {' '.join(args)} exited {result.returncode}\nstderr: {result.stderr}"
        )
    return result


class Sandbox:
    """One temp HOME shared by one or more atrium data dirs (stable, dev, ...)."""

    def __init__(self, testcase, instances=1, adapters=("shared", "claude-code")):
        self._tmp = tempfile.TemporaryDirectory()
        testcase.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        self.data_dirs = []
        for index in range(instances):
            data_dir = root / f"data-{index}"
            install_like_atrium(data_dir, adapters)
            self.data_dirs.append(data_dir)
        self.env = isolated_env(self.home, self.data_dirs[0])

    def script(self, adapter, name, instance=0):
        return self.data_dirs[instance] / "adapters" / adapter / name


def has_atrium_hooks(settings):
    commands = [
        hook.get("command", "")
        for entry in (settings.get("hooks") or {}).get("SessionStart", [])
        for hook in entry.get("hooks", [])
    ]
    return any("atrium-runtime-hook" in command for command in commands)


class HookEntrypointsFromInstalledLayout(unittest.TestCase):
    def test_hooks_install_status_uninstall_through_managed_symlinks(self):
        for adapter in ("claude-code", "codex"):
            for entry in ("logical", "physical"):
                with self.subTest(adapter=adapter, entry=entry):
                    box = Sandbox(self, adapters=("shared", adapter))
                    hooks = box.script(adapter, "hooks.sh")
                    if entry == "physical":
                        hooks = Path(os.path.realpath(hooks))
                        self.assertIn("/.managed/", str(hooks))
                    for operation, installed in (
                        ("install", True),
                        ("install", True),
                        ("uninstall", False),
                    ):
                        run(hooks, operation, env=box.env)
                        status = json.loads(run(hooks, "status", env=box.env).stdout)
                        self.assertIs(status["installed"], installed, f"after {operation}")

    def test_uninstall_strips_hooks_an_earlier_install_left_behind(self):
        box = Sandbox(self)
        settings = box.home / ".claude" / "settings.json"
        run(ADAPTERS / "claude-code/hooks.sh", "install", env=box.env)
        self.assertTrue(has_atrium_hooks(json.loads(settings.read_text())))
        run(box.script("claude-code", "hooks.sh"), "uninstall", env=box.env)
        self.assertNotIn("hooks", json.loads(settings.read_text()))

    def test_stop_normalizers_reach_the_shared_settle_wait(self):
        for adapter, mode in (("claude-code", "claude"), ("grok", "grok")):
            with self.subTest(adapter=adapter):
                box = Sandbox(self, adapters=("shared", adapter))
                recorder = box.data_dirs[0] / "settle.log"
                settle = (
                    box.data_dirs[0] / "adapters/.managed/shared/generations" / GENERATION
                    / "await-transcript-settle.sh"
                )
                settle.write_text(f'#!/bin/sh\nprintf "%s %s\\n" "$1" "$2" >> "{recorder}"\n')
                settle.chmod(0o755)
                transcript = box.home / "transcript.jsonl"
                transcript.write_text('{"type":"user","message":{"content":"hi"}}\n')
                payload = json.dumps({"session_id": "s1", "transcript_path": str(transcript)})
                run(box.script(adapter, "normalize-hook-payload.sh"), "stop", env=box.env, stdin=payload)
                self.assertTrue(recorder.exists(), "the stop normalizer never ran the settle wait")
                self.assertEqual(recorder.read_text(), f"{mode} {transcript}\n")

    def test_other_shared_runtime_consumers_resolve_from_installed_layout(self):
        box = Sandbox(self, adapters=("shared", "goose", "grok"))
        update = run(box.script("goose", "check_update.sh"), env=box.env)
        self.assertEqual(json.loads(update.stdout)["error"], "goose not found")

        env = {key: value for key, value in box.env.items() if key != "ATRIUM_DATA_DIR"}
        rules = run(box.script("grok", "atrium-session-rules.sh"), env=env)
        first_line = (ADAPTERS / "shared/atrium-context.md").read_text().splitlines()[0]
        self.assertIn(first_line, rules.stdout)

    def test_scripts_never_reach_shared_through_a_parent_path(self):
        # `..` after an adapter dir is resolved physically through the managed
        # symlink. Resolve the logical adapter dir and take its parent instead.
        banned = re.compile(r'\.\./shared|dirname "\$0"\)/\.\.')
        offenders = []
        for script in sorted(ADAPTERS.glob("*/**/*.sh")):
            relative = script.relative_to(ADAPTERS)
            if relative.parts[0] == "shared" or "tests" in relative.parts:
                continue
            for number, line in enumerate(script.read_text(encoding="utf-8").splitlines(), 1):
                if not line.lstrip().startswith("#") and banned.search(line):
                    offenders.append(f"adapters/{relative}:{number}: {line.strip()}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()

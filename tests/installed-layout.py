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
import stat
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = ROOT / "adapters"
GENERATION = f"{'a' * 64}-{'b' * 40}"
MARKER = "atrium-statusline-relay"


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

    def env_for(self, instance):
        return {**self.env, "ATRIUM_DATA_DIR": str(self.data_dirs[instance])}

    def link_settings(self, content='{"userSetting": true}\n', mode=0o640):
        """~/.claude/settings.json as a symlink into a dotfiles dir (issue #137)."""
        dotfiles = self.home / "dotfiles"
        dotfiles.mkdir(exist_ok=True)
        target = dotfiles / "settings.json"
        target.write_text(content)
        target.chmod(mode)
        link = self.home / ".claude" / "settings.json"
        link.parent.mkdir(exist_ok=True)
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(os.path.relpath(target, link.parent))
        return link, target


def statusline_command(settings):
    return (settings.get("statusLine") or {}).get("command", "")


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


class ClaudeSettingsWrites(unittest.TestCase):
    def test_steady_state_passes_leave_settings_untouched(self):
        for layout in ("plain", "symlinked"):
            box = Sandbox(self)
            link, target = box.link_settings()
            if layout == "plain":
                link.unlink()
                shutil.move(target, link)
                target = link
            for script in ("statusline.sh", "hooks.sh"):
                with self.subTest(layout=layout, script=script):
                    path = box.script("claude-code", script)
                    run(path, "install", env=box.env)
                    before = target.stat()
                    listing = sorted(os.listdir(target.parent)) + sorted(os.listdir(link.parent))
                    time.sleep(0.02)
                    run(path, "install", env=box.env)
                    run(path, "install", env=box.env)
                    after = target.stat()
                    self.assertEqual(link.is_symlink(), layout == "symlinked")
                    self.assertEqual(after.st_ino, before.st_ino, f"{script} replaced an unchanged file")
                    self.assertEqual(after.st_mtime_ns, before.st_mtime_ns, f"{script} rewrote an unchanged file")
                    self.assertEqual(sorted(os.listdir(target.parent)) + sorted(os.listdir(link.parent)), listing)

    def test_statusline_writes_through_a_symlinked_settings_file(self):
        box = Sandbox(self)
        link, target = box.link_settings(
            '{"userSetting": true, "statusLine": {"type": "command", "command": "my-line"}}\n'
        )
        statusline = box.script("claude-code", "statusline.sh")
        run(statusline, "install", env=box.env)
        self.assertTrue(link.is_symlink(), "install replaced the settings symlink")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
        settings = json.loads(target.read_text())
        self.assertTrue(settings["userSetting"])
        self.assertIn(MARKER, statusline_command(settings))
        self.assertEqual((box.home / ".claude/.atrium-statusline-chain").read_text(), "my-line")

        run(statusline, "uninstall", env=box.env)
        self.assertTrue(link.is_symlink(), "uninstall replaced the settings symlink")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
        self.assertEqual(statusline_command(json.loads(target.read_text())), "my-line")

    def test_concurrent_installs_from_two_instances_lose_no_edits(self):
        box = Sandbox(self, instances=2)
        for round_number in range(6):
            link, target = box.link_settings()
            processes = [
                subprocess.Popen(
                    [str(box.script("claude-code", name, instance)), "install"],
                    env=box.env_for(instance),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for instance in (0, 1)
                for name in ("hooks.sh", "statusline.sh")
            ]
            for process in processes:
                _, stderr = process.communicate(timeout=120)
                self.assertEqual(process.returncode, 0, f"round {round_number}: {stderr}")
            self.assertTrue(link.is_symlink(), f"round {round_number}: settings symlink replaced")
            settings = json.loads(target.read_text())
            self.assertTrue(settings.get("userSetting"), f"round {round_number}: user edit lost")
            self.assertTrue(has_atrium_hooks(settings), f"round {round_number}: hooks lost")
            self.assertIn(MARKER, statusline_command(settings), f"round {round_number}: statusLine lost")
        self.assertFalse((box.home / ".claude/.atrium-settings.lock").exists(), "lock left behind")

    def test_steady_state_passes_never_clobber_a_concurrent_settings_writer(self):
        box = Sandbox(self, instances=2)
        link, target = box.link_settings()
        run(box.script("claude-code", "hooks.sh"), "install", env=box.env)
        run(box.script("claude-code", "statusline.sh"), "install", env=box.env)

        stop = box.home / "stop"
        loop = 'while [ ! -e "$1" ]; do "$2" install >/dev/null && "$3" install >/dev/null || exit 1; done'
        installers = [
            subprocess.Popen(
                [
                    "bash", "-c", loop, "loop", str(stop),
                    str(box.script("claude-code", "statusline.sh", instance)),
                    str(box.script("claude-code", "hooks.sh", instance)),
                ],
                env=box.env_for(instance),
                stderr=subprocess.PIPE,
                text=True,
            )
            for instance in (0, 1)
        ]

        # Claude Code (or the user's editor) rewriting the file atomically while
        # atrium passes run; JSON.stringify(_, null, 2) formatting, like jq's.
        edits = 150
        for index in range(edits):
            real = Path(os.path.realpath(link))
            settings = json.loads(real.read_text())
            settings[f"edit-{index}"] = index
            scratch = real.with_name(f".writer-{index}")
            scratch.write_text(json.dumps(settings, indent=2) + "\n")
            os.replace(scratch, real)
            time.sleep(0.004)
        stop.touch()
        for installer in installers:
            _, stderr = installer.communicate(timeout=120)
            self.assertEqual(installer.returncode, 0, stderr)

        settings = json.loads(link.read_text())
        lost = [index for index in range(edits) if f"edit-{index}" not in settings]
        self.assertEqual(lost, [], f"{len(lost)}/{edits} concurrent edits were lost")
        self.assertTrue(link.is_symlink())

    def test_stale_locks_are_taken_over(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        cases = (
            ("dead owner", f"{dead.pid}\n", 0),
            # A live process the user owns, e.g. a reused PID.
            ("old lock held by a live pid", f"{os.getpid()}\n", 120),
            ("owner died before writing its pid", "", 120),
            ("not a pid", "not-a-pid\n", 0),
        )
        for name, content, age in cases:
            with self.subTest(name):
                box = Sandbox(self)
                box.link_settings()
                lock = box.home / ".claude/.atrium-settings.lock"
                lock.write_text(content)
                if age:
                    then = time.time() - age
                    os.utime(lock, (then, then))
                started = time.monotonic()
                run(box.script("claude-code", "statusline.sh"), "install", env=box.env)
                self.assertLess(time.monotonic() - started, 3, "waited on a stale lock")
                self.assertFalse(lock.exists())

    def test_a_live_lock_is_waited_for(self):
        box = Sandbox(self)
        link, target = box.link_settings()
        lock = box.home / ".claude/.atrium-settings.lock"
        lock.write_text(f"{os.getpid()}\n")
        installer = subprocess.Popen(
            [str(box.script("claude-code", "statusline.sh")), "install"],
            env=box.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        )
        time.sleep(0.6)
        self.assertIsNone(installer.poll(), "took a lock its live owner still holds")
        self.assertNotIn("statusLine", json.loads(target.read_text()))
        lock.unlink()
        _, stderr = installer.communicate(timeout=30)
        self.assertEqual(installer.returncode, 0, stderr)
        self.assertIn(MARKER, statusline_command(json.loads(target.read_text())))

if __name__ == "__main__":
    unittest.main()

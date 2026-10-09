import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class HookConfigSymlinks(unittest.TestCase):
    def test_unchanged_content_keeps_target_inode_and_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.json"
            target.write_text('{"unchanged": true}\n')
            link = root / "config.json"
            link.symlink_to(target)
            before = target.stat()
            subprocess.run([
                "bash", "-c",
                'source "$1"; tmp="$(atrium_config_temp "$2")"; atrium_config_commit "$tmp" "$2"',
                "test", str(ROOT / "adapters/shared/config-file.sh"), str(link),
            ], check=True)
            self.assertTrue(link.is_symlink())
            self.assertEqual(target.stat().st_ino, before.st_ino)
            self.assertEqual(target.stat().st_mtime_ns, before.st_mtime_ns)

    def test_install_and_uninstall_preserve_links_and_modes(self):
        for adapter, names in (
            ("claude-code", [".claude/settings.json"]),
            ("codex", [".codex/config.toml", ".codex/hooks.json"]),
        ):
            with self.subTest(adapter=adapter), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                targets = home / "dot files"
                targets.mkdir()
                binaries = home / "bin"
                binaries.mkdir()
                for binary in ("claude", "codex"):
                    stub = binaries / binary
                    stub.write_text("#!/bin/sh\nexit 0\n")
                    stub.chmod(0o755)
                pairs = []
                for name in names:
                    link = home / name
                    link.parent.mkdir(exist_ok=True)
                    target = targets / link.name
                    target.write_text('model = "fixture"\n' if name.endswith("toml") else '{"userSetting": true}\n')
                    target.chmod(0o640)
                    intermediate = targets / (link.name + ".link")
                    intermediate.symlink_to(target.name)
                    link.symlink_to(os.path.relpath(intermediate, link.parent))
                    pairs.append((link, target))
                env = {**os.environ, "HOME": str(home), "PATH": f"{binaries}:{os.environ['PATH']}"}
                for operation in ("install", "install", "uninstall", "uninstall"):
                    subprocess.run([str(ROOT / "adapters" / adapter / "hooks.sh"), operation], env=env, check=True, capture_output=True)
                    for link, target in pairs:
                        self.assertTrue(link.is_symlink(), f"{operation} replaced {link}")
                        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
                        self.assertEqual(link.read_bytes(), target.read_bytes())
                        if link.suffix == ".json":
                            content = json.loads(target.read_text())
                            self.assertTrue(content["userSetting"])
                            self.assertEqual(bool(content.get("hooks")), operation == "install")
                        else:
                            self.assertIn('model = "fixture"', target.read_text())
                            if operation == "install":
                                self.assertIn(f'[hooks.state."{home}/.codex/hooks.json:', target.read_text())


if __name__ == "__main__":
    unittest.main()

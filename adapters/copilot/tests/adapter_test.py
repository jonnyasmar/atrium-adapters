import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

ADAPTER = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ADAPTER))
import hooks
import sessions


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="atrium-copilot-test-")
        self.root = Path(self.temp.name)
        self.home = self.root / "copilot"
        self.data = self.root / "atrium dev"
        self.env = patch.dict(os.environ, {"COPILOT_HOME": str(self.home), "ATRIUM_DATA_DIR": str(self.data),
                                          "ATRIUM_TEST_TRANSCRIPT_ROOT": str(self.home / "session-state")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.temp.cleanup)

    def script(self, name, *args, **kwargs):
        return subprocess.run(["bash", str(ADAPTER / name), *args], text=True, capture_output=True, **kwargs)

    def fixture(self, session_id="copilot-fixture", cwd="/work/proj", parent=None):
        path = sessions.session_path(session_id)
        path.parent.mkdir(parents=True)
        rows = list(sessions.records(ADAPTER / "tests/extractor/copilot-fixture/events.jsonl"))
        rows[0]["data"]["sessionId"] = session_id
        rows[0]["data"]["context"]["cwd"] = cwd
        if parent:
            rows[0]["data"]["parentSessionId"] = parent
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        return path

    def test_launch_preserves_literal_argv(self):
        args = ["--add-dir", "/work/a b", "--agent", "$(touch bad);`echo nope`"]
        flags = {"model": "auto", "effort": "high", "extraArgv": args, "dangerouslySkipPermissions": True}
        result = self.script("build_launch_command.sh", json.dumps(flags), check=True)
        self.assertEqual(json.loads(result.stdout)["command"], ["copilot", "--allow-all", "--model", "auto", "--reasoning-effort", "high", *args])

    def test_resume_and_false_permissions(self):
        result = self.script("build_resume_command.sh", "session with spaces", "{}", check=True)
        self.assertEqual(json.loads(result.stdout)["command"], ["copilot", "--resume", "session with spaces"])

    def test_invalid_extra_argv_is_rejected(self):
        self.assertNotEqual(self.script("build_launch_command.sh", '{"extraArgv":[1]}').returncode, 0)

    def test_hook_fixtures(self):
        for directory in (ADAPTER / "tests/fixtures").iterdir():
            with self.subTest(event=directory.name):
                raw = json.loads((directory / "tool-input.json").read_text())
                expected = json.loads((directory / "expected-atrium.json").read_text())
                self.assertEqual(hooks.normalize(directory.name, raw), expected)

    def test_failed_write_has_no_attribution(self):
        raw = {"toolName": "edit", "toolArgs": {"path": "/work/a"}, "error": "denied"}
        self.assertNotIn("_atrium", hooks.normalize("post-tool-use", raw))

    def test_patch_attribution_includes_renames_and_paths_with_spaces(self):
        raw = {"cwd": "/work/proj", "toolName": "apply_patch", "toolArgs": "*** Begin Patch\n*** Update File: old name.py\n*** Move to: new name.py\n*** Add File: extra.py\n*** End Patch\n"}
        result = hooks.normalize("post-tool-use", raw)
        self.assertEqual(result["_atrium"]["filePaths"], ["/work/proj/old name.py", "/work/proj/new name.py", "/work/proj/extra.py"])

    def test_snake_case_input_stays_compatible(self):
        value = hooks.normalize("pre-tool-use", {"session_id": "s", "tool_name": "Read", "tool_input": {"path": "a"}})
        self.assertEqual(value["session_id"], "s")
        self.assertEqual(json.loads(value["tool_input"]), {"path": "a"})

    def test_install_is_idempotent_and_preserves_other_hooks(self):
        other = self.home / "hooks/user.json"
        other.parent.mkdir(parents=True)
        other.write_text('{"version":1,"hooks":{}}')
        hooks.manage("install")
        installed = (other.parent / "atrium.json").read_bytes()
        hooks.manage("install")
        self.assertEqual(installed, (other.parent / "atrium.json").read_bytes())
        self.assertTrue(hooks.manage("status")["activityHooks"])
        config = json.loads(installed)
        self.assertEqual(set(config["hooks"]), set(hooks.EVENTS))
        for event, entries in config["hooks"].items():
            self.assertEqual(entries[0]["args"], [str(self.data / "adapters/copilot/copilot-hook.sh"), event, str(self.data), os.environ.get("ATRIUM_CLI_PATH", "atrium")])
        hooks.manage("uninstall")
        self.assertFalse((other.parent / "atrium.json").exists())
        self.assertTrue(other.exists())

    def test_uninstall_does_not_remove_another_instances_hooks(self):
        hooks.manage("install")
        with patch.dict(os.environ, {"ATRIUM_DATA_DIR": str(self.root / "other-instance")}):
            self.assertFalse(hooks.manage("status")["installed"])
            hooks.manage("uninstall")
        self.assertTrue(hooks.manage("status")["installed"])

    def test_no_hooks_outside_atrium_or_in_chat(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(hooks, "post_event") as post:
            self.assertEqual(hooks.emit("preToolUse", {}), {})
            post.assert_not_called()
        with patch.dict(os.environ, {"ATRIUM_PANE_ID": "pane", "ATRIUM_CHAT_SDK_HOOKS": "1"}), patch.object(hooks, "post_event") as post:
            self.assertEqual(hooks.emit("preToolUse", {}), {})
            post.assert_not_called()

    def test_subagent_turns_and_recoverable_errors_do_not_stop_parent(self):
        with patch.dict(os.environ, {"ATRIUM_PANE_ID": "pane", "ATRIUM_CHAT_SDK_HOOKS": ""}), patch.object(hooks, "post_event") as post:
            self.assertEqual(hooks.emit("agentStop", {"agentId": "child"}), {})
            self.assertEqual(hooks.emit("errorOccurred", {"recoverable": True}), {})
            post.assert_not_called()

    def test_context_shapes_and_permission_neutrality(self):
        with patch.dict(os.environ, {"ATRIUM_PANE_ID": "pane", "ATRIUM_CHAT_SDK_HOOKS": ""}), \
             patch.object(hooks, "post_event", return_value="live"), patch.object(hooks, "skill_context", return_value="skills"):
            self.assertEqual(hooks.emit("sessionStart", {}), {"additionalContext": "skills\n\nlive"})
            self.assertEqual(hooks.emit("userPromptTransformed", {"prompt": "visible", "transformedPrompt": "original"}),
                             {"modifiedTransformedPrompt": "skills\n\nlive\n\noriginal"})
            self.assertEqual(hooks.emit("preToolUse", {}), {})

    def test_bridge_failure_retains_skill_context(self):
        with patch.dict(os.environ, {"ATRIUM_PANE_ID": "pane", "ATRIUM_CHAT_SDK_HOOKS": ""}), \
             patch.object(hooks, "post_event", side_effect=OSError("offline")), patch.object(hooks, "skill_context", return_value="manifest"):
            self.assertEqual(hooks.emit("sessionStart", {}), {"additionalContext": "manifest"})

    def test_http_emits_normalized_payload_with_pane_identity(self):
        received = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append((self.path, self.headers.get("X-Atrium-Pane-Id"), json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"ok":true,"atriumContext":"context"}')

            def log_message(self, *_args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        self.data.mkdir(parents=True)
        (self.data / "hook-port").write_text(str(server.server_port))
        thread.start()
        try:
            with patch.dict(os.environ, {"ATRIUM_PANE_ID": "test-pane"}):
                self.assertEqual(hooks.post_event("pre-tool-use", {"session_id": "s"}), "context")
        finally:
            thread.join(timeout=5)
            server.server_close()
        self.assertEqual(received, [("/api/adapter/copilot/pre-tool-use", "test-pane", {"session_id": "s"})])

    def test_runtime_hook_uses_calling_instance_and_fails_open(self):
        target = self.data / "adapters/copilot"
        target.mkdir(parents=True)
        shutil.copy(ADAPTER / "run-python.sh", target)
        (target / "hooks.py").write_text("import sys; print('{}'); sys.exit(7)")
        with patch.dict(os.environ, {"ATRIUM_PANE_ID": "pane", "ATRIUM_CHAT_SDK_HOOKS": ""}):
            result = self.script("copilot-hook.sh", "preToolUse", "/wrong-instance", input="{}")
        self.assertEqual(result.returncode, 0)
        self.assertIn("{}", result.stdout)

    def test_listing_filters_workspace_and_children_and_orders_by_activity(self):
        first = self.fixture()
        second = self.fixture("second")
        self.fixture("other", "/work/proj-other")
        self.fixture("child", parent="copilot-fixture")
        os.utime(first, (100, 100))
        os.utime(second, (200, 200))
        (second.parent / "workspace.yaml").write_text('name: "A quoted \\"title\\""\n')
        result = sessions.list_sessions("/work/proj")["sessions"]
        self.assertEqual([row["id"] for row in result], ["second", "copilot-fixture"])
        self.assertEqual(result[0]["name"], 'A quoted "title"')
        self.assertEqual(result[0]["sourceSize"], second.stat().st_size)

    def test_missing_sessions_are_empty_and_invalid_id_cannot_escape_root(self):
        self.assertEqual(sessions.list_sessions("/work/proj"), {"sessions": []})
        with self.assertRaises(ValueError):
            sessions.session_path("../../secrets")

    def test_lister_without_python_returns_empty_sessions_and_a_reason(self):
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        (binary_dir / "bash").symlink_to(shutil.which("bash"))
        result = self.script("list_recent_sessions.sh", "/work/proj", env={**os.environ, "PATH": str(binary_dir)})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"sessions": []})
        self.assertIn("list_recent_sessions: no runnable Python 3", result.stderr)

    def test_stop_reads_current_reply_but_never_previous_turn(self):
        path = self.fixture()
        self.assertEqual(sessions.last_assistant(path), "Changed the greeting to hi.")
        with path.open("a") as stream:
            stream.write(json.dumps({"type": "user.message", "data": {"content": "Next turn"}}) + "\n")
            stream.write('{"partial":')
        self.assertEqual(sessions.last_assistant(path), "")

    def test_stop_waits_for_its_flush_marker_and_rejects_a_newer_turn(self):
        path = self.fixture()
        self.assertEqual(sessions.stop_snapshot(path, 123), (False, False, ""))
        with path.open("a") as stream:
            stream.write(json.dumps({"type": "hook.start", "data": {"hookType": "agentStop", "input": {"timestamp": 123}}}) + "\n")
        self.assertEqual(sessions.stop_snapshot(path, 123), (True, False, "Changed the greeting to hi."))
        with path.open("a") as stream:
            stream.write(json.dumps({"type": "user.message", "data": {"content": "Next turn"}}) + "\n")
        self.assertEqual(sessions.stop_snapshot(path, 123), (True, True, ""))

    def test_deferred_stop_sends_one_current_reply_and_no_stale_stop(self):
        payload = {"transcriptPath": "/missing", "timestamp": 123, "sessionId": "s"}
        with patch.object(sessions, "stop_snapshot", side_effect=[(False, False, ""), (True, False, "current")]), \
             patch("time.sleep"), patch.object(hooks, "post_event") as post:
            hooks.deliver_stop(payload)
            post.assert_called_once()
            self.assertEqual(post.call_args.args[1]["last_assistant_message"], "current")
        with patch.object(sessions, "stop_snapshot", return_value=(True, True, "")), patch.object(hooks, "post_event") as post:
            hooks.deliver_stop(payload)
            post.assert_not_called()

    def test_stop_worker_timeout_never_uses_a_previous_reply(self):
        with patch.object(sessions, "stop_snapshot", return_value=(False, False, "")), patch("time.sleep"), \
             patch.object(hooks, "last_assistant", return_value="previous"), patch.object(hooks, "post_event") as post:
            hooks.deliver_stop({"transcriptPath": "/missing", "timestamp": 123})
            self.assertNotIn("last_assistant_message", post.call_args.args[1])

    def test_extractor_depths_and_private_context(self):
        self.fixture()
        for depth, count in [("quick", 2), ("standard", 5), ("deep", 6)]:
            with self.subTest(depth=depth):
                result = self.script("extract_session.sh", "--session-id", "copilot-fixture", "--cwd", "/work/proj", "--depth", depth, check=True)
                events = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(len(events), count)
                self.assertEqual(events[-1]["event_count"], count)
                self.assertNotIn("PRIVATE_", result.stdout)
                if depth == "deep":
                    self.assertEqual(events[3]["text"], "Updated hello.py")

    def test_extractor_missing_session_fails_with_reason(self):
        result = self.script("extract_session.sh", "--session-id", "missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("session transcript not found", result.stderr)


if __name__ == "__main__":
    unittest.main()

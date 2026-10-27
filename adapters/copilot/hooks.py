import json
import os
import re
import sys
from pathlib import Path

from sessions import home, last_assistant, session_path

EVENTS = {
    "sessionStart": "session-start",
    "sessionEnd": "session-end",
    "userPromptTransformed": "user-prompt-submit",
    "preToolUse": "pre-tool-use",
    "postToolUse": "post-tool-use",
    "postToolUseFailure": "post-tool-use",
    "agentStop": "stop",
    "errorOccurred": "stop-failure",
    "subagentStart": "subagent-start",
    "subagentStop": "subagent-stop",
}


def normalize(event, payload):
    result = dict(payload)
    for native, canonical in {
        "sessionId": "session_id", "toolName": "tool_name", "toolCallId": "tool_use_id",
        "transcriptPath": "transcript_path", "agentId": "agent_id", "agentType": "agent_type",
        "agentName": "agent_name", "prompt": "user_prompt",
    }.items():
        if native in payload:
            result[canonical] = payload[native]
    args = payload.get("toolArgs", payload.get("tool_input"))
    if args is not None:
        result["tool_input"] = args if isinstance(args, str) else json.dumps(args, separators=(",", ":"))
    native_result = payload.get("toolResult", payload.get("tool_result"))
    if native_result is not None:
        if isinstance(native_result, dict):
            result["tool_response"] = native_result.get("textResultForLlm", native_result.get("text_result_for_llm", json.dumps(native_result)))
        else:
            result["tool_response"] = str(native_result)
    error = payload.get("error")
    if isinstance(error, dict):
        result["error"] = error.get("message", "Copilot error")
    if event == "post-tool-use-failure" and not result.get("error"):
        result["error"] = "tool failed"
    if event == "post-tool-use" and not result.get("error"):
        patch_text = args if isinstance(args, str) else ""
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                args = None
        tool = result.get("tool_name")
        if tool == "apply_patch":
            if isinstance(args, dict):
                patch_text = args.get("patch", args.get("input", ""))
            if isinstance(patch_text, str):
                paths = re.findall(r"^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$", patch_text, re.MULTILINE)
                paths = list(dict.fromkeys(os.path.join(payload.get("cwd", ""), path) for path in paths))
                if paths:
                    result["_atrium"] = {"writeKind": "multi-edit" if len(paths) > 1 else "edit", "filePaths": paths,
                                         "lineStart": None, "lineEnd": None}
        if isinstance(args, dict) and tool in ("create", "edit", "str_replace_editor", "Write", "Edit"):
            path = args.get("path") or args.get("file_path")
            if isinstance(path, str) and path:
                result["_atrium"] = {"writeKind": "write" if tool in ("create", "Write") else "edit",
                                     "filePaths": [path], "lineStart": None, "lineEnd": None}
    if event == "subagent-stop" and isinstance(payload.get("response"), str):
        result["last_assistant_message"] = payload["response"]
    if event == "stop":
        try:
            path = result.get("transcript_path") or session_path(result.get("session_id", ""))
            message = last_assistant(path)
            if message:
                result["last_assistant_message"] = message
        except (OSError, ValueError, TypeError):
            pass
    return result


def hook_config(data_dir):
    import shutil
    import subprocess
    script = Path(data_dir) / "adapters/copilot/copilot-hook.sh"
    bash = shutil.which("bash") or "/bin/bash"
    if os.name == "nt":
        converted = subprocess.run(["cygpath", "-w", bash], capture_output=True, text=True, check=True)
        bash = converted.stdout.strip()
    return {"version": 1, "hooks": {
        event: [{"type": "command", "exec": bash,
                 "args": [script.as_posix(), event, Path(data_dir).as_posix()], "timeoutSec": 5}]
        for event in EVENTS
    }}


def manage(command):
    target = home() / "hooks/atrium.json"
    data_dir = os.environ.get("ATRIUM_DATA_DIR")
    if not data_dir:
        raise ValueError("ATRIUM_DATA_DIR is required to manage Copilot hooks")
    expected = hook_config(data_dir)
    if command == "install":
        import tempfile
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=target.parent, delete=False) as stream:
            temp = Path(stream.name)
            json.dump(expected, stream, indent=2)
            stream.write("\n")
        try:
            os.replace(temp, target)
        finally:
            temp.unlink(missing_ok=True)
        return {"subcommand": command, "installed": True}
    try:
        actual = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        actual = None
    owned = actual == expected
    if command == "uninstall":
        # Another atrium instance may have installed this shared hook file.
        if owned:
            target.unlink()
        return {"subcommand": command, "uninstalled": True}
    return {"subcommand": command, "installed": owned, "activityHooks": owned}


def post_event(event, payload):
    from urllib.request import Request, build_opener, ProxyHandler
    data_dir = os.environ.get("ATRIUM_DATA_DIR")
    pane = os.environ.get("ATRIUM_PANE_ID")
    if not data_dir or not pane:
        return ""
    port = int((Path(data_dir) / "hook-port").read_text().strip())
    if not 0 < port < 65536:
        return ""
    request = Request(f"http://127.0.0.1:{port}/api/adapter/copilot/{event}",
                      data=json.dumps(payload).encode(),
                      headers={"Content-Type": "application/json", "X-Atrium-Pane-Id": pane})
    # Never send the local bridge payload through a configured HTTP proxy.
    with build_opener(ProxyHandler({})).open(request, timeout=2) as response:
        value = json.load(response).get("atriumContext", "")
        return value if isinstance(value, str) else ""


def skill_context(native, payload):
    import subprocess
    cli = os.environ.get("ATRIUM_CLI_PATH")
    if not cli or native not in ("sessionStart", "userPromptTransformed"):
        return ""
    verb = "resolve-manifest" if native == "sessionStart" else "resolve-prompt-sigils"
    try:
        result = subprocess.run([cli, "skills", verb, "--pane-id", os.environ["ATRIUM_PANE_ID"], "--adapter", "copilot"],
                                input=json.dumps(payload), capture_output=True, text=True, timeout=2, check=True)
        if native == "sessionStart":
            return result.stdout.strip()
        envelope = json.loads(result.stdout or "{}")
        context = (envelope.get("hookSpecificOutput") or {}).get("additionalContext", "")
        return context if isinstance(context, str) else ""
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""


def emit(native, payload):
    if not os.environ.get("ATRIUM_PANE_ID") or os.environ.get("ATRIUM_CHAT_SDK_HOOKS") == "1":
        return {}
    event = EVENTS.get(native)
    if not event:
        return {}
    # Root activity must not stop or restart when an internal child turns.
    if payload.get("agentId") and native not in ("subagentStart", "subagentStop"):
        return {}
    if native == "errorOccurred" and payload.get("recoverable"):
        return {}
    normalized = normalize("post-tool-use-failure" if native == "postToolUseFailure" else event, payload)
    try:
        live_context = post_event(event, normalized)
    except Exception as error:
        print(f"copilot hook bridge: {error}", file=sys.stderr)
        live_context = ""
    context = "\n\n".join(part for part in (skill_context(native, normalized), live_context) if part)
    if not context:
        return {}
    if native == "sessionStart":
        return {"additionalContext": context}
    if native == "userPromptTransformed" and isinstance(payload.get("transformedPrompt"), str):
        return {"modifiedTransformedPrompt": context + "\n\n" + payload["transformedPrompt"]}
    return {}


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if command in ("install", "status", "uninstall"):
            result = manage(command)
        elif command in ("normalize", "emit"):
            payload = json.load(sys.stdin)
            if not isinstance(payload, dict):
                raise ValueError("hook payload must be an object")
            event = sys.argv[2] if len(sys.argv) > 2 else ""
            result = normalize(event, payload) if command == "normalize" else emit(event, payload)
        else:
            raise ValueError(f"unknown hooks command: {command}")
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Exception as error:
        if command == "emit":
            print("{}")
            print(f"copilot hook: {error}", file=sys.stderr)
            return 0
        print(f"copilot hooks: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

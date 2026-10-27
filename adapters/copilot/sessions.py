import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def home():
    return Path(os.environ.get("COPILOT_HOME", str(Path.home() / ".copilot")))


def root():
    return Path(os.environ.get("ATRIUM_TEST_TRANSCRIPT_ROOT", str(home() / "session-state")))


def session_path(session_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
        raise ValueError("invalid session id")
    return root() / session_id / "events.jsonl"


def records(path):
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict) and isinstance(value.get("data"), dict):
                yield value


def iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(item.get("text", "") for item in value if isinstance(item, dict) and isinstance(item.get("text"), str))
    return ""


def metadata(path):
    first = next(records(path), None)
    if not first or first.get("type") != "session.start":
        return None
    data = first["data"]
    context = data.get("context") or {}
    if not isinstance(context, dict):
        return None
    if data.get("parentSessionId") or data.get("parentAgentId") or data.get("isSubagent"):
        return None
    return first, context


def list_sessions(cwd):
    entries = []
    if not root().is_dir():
        return {"sessions": []}
    for directory in root().iterdir():
        path = directory / "events.jsonl"
        if not directory.is_dir() or not path.is_file():
            continue
        try:
            meta = metadata(path)
            if not meta:
                continue
            first, context = meta
            actual = context.get("cwd")
            if not isinstance(actual, str) or os.path.normcase(os.path.realpath(actual)) != os.path.normcase(os.path.realpath(cwd)):
                continue
            info = path.stat()
            title = None
            # Copilot writes its display name as a single YAML scalar; transcript
            # JSON remains authoritative for identity and workspace filtering.
            workspace = directory / "workspace.yaml"
            if workspace.is_file():
                for line in workspace.read_text(encoding="utf-8", errors="replace").splitlines():
                    if line.startswith("name: "):
                        title = line[6:]
                        if title.startswith('"'):
                            try:
                                title = json.loads(title)
                            except ValueError:
                                title = None
                        elif title.startswith("'") and title.endswith("'"):
                            title = title[1:-1].replace("''", "'")
                        elif title in ("|", ">", "|-", ">-"):
                            title = None
                        break
            entries.append({"id": first["data"].get("sessionId", directory.name), "name": title,
                            "cwd": actual, "lastActive": iso(info.st_mtime), "sourcePath": str(path),
                            "sourceMtimeNanos": info.st_mtime_ns, "sourceSize": info.st_size})
        except (OSError, ValueError, TypeError):
            continue
    entries.sort(key=lambda item: item["sourceMtimeNanos"], reverse=True)
    return {"sessions": entries[:20]}


def tail_records(path):
    # Bound hook work even when a transcript contains large opaque model blobs.
    with Path(path).open("rb") as stream:
        stream.seek(0, 2)
        start = max(0, stream.tell() - 262144)
        stream.seek(start)
        if start:
            stream.readline()
        lines = stream.read().decode("utf-8", errors="replace").splitlines()
    for line in reversed(lines):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and isinstance(event.get("data"), dict):
            yield event


def last_assistant(path):
    for event in tail_records(path):
        if event.get("type") == "user.message":
            break
        if event.get("type") == "assistant.message":
            return text((event.get("data") or {}).get("content"))
    return ""


def stop_snapshot(path, timestamp):
    try:
        events = list(tail_records(path))
    except OSError:
        return False, False, ""
    found = False
    newer_user = False
    for event in events:
        data = event["data"]
        if not found:
            if event.get("type") == "user.message":
                newer_user = True
            hook_input = data.get("input") or {}
            if event.get("type") == "hook.start" and data.get("hookType") == "agentStop" and isinstance(hook_input, dict) and hook_input.get("timestamp") == timestamp:
                if newer_user:
                    return True, True, ""
                found = True
        elif event.get("type") == "assistant.message":
            return True, False, text(data.get("content"))
        elif event.get("type") == "user.message":
            break
    return found, False, ""


def extract(session_id, cwd, depth):
    path = session_path(session_id)
    if not path.is_file():
        raise FileNotFoundError(f"session transcript not found: {session_id}")
    meta = metadata(path)
    if not meta:
        raise ValueError("session transcript has no top-level session.start")
    first, context = meta
    started = first["data"].get("startTime") or first.get("timestamp") or iso(path.stat().st_mtime)
    end = started
    count = 0

    def emit(event):
        nonlocal count
        print(json.dumps(event, ensure_ascii=False))
        count += 1

    emit({"type": "session_start", "session_id": session_id, "adapter": "copilot", "cwd": context.get("cwd", cwd), "started_at": started})
    if depth == "quick":
        end = iso(path.stat().st_mtime)
    else:
        tools = {}
        for event in records(path):
            data = event["data"]
            kind = event.get("type")
            end = event.get("timestamp") or end
            if kind in ("user.message", "assistant.message"):
                content = text(data.get("content"))
                if content:
                    emit({"type": "prose", "role": kind.split(".")[0], "text": content, "at": end})
            elif kind == "tool.execution_start":
                tool = data.get("toolName", "unknown")
                call_id = data.get("toolCallId") or event.get("id")
                if not isinstance(call_id, str) or not call_id:
                    continue
                args = data.get("arguments") or {}
                if not isinstance(args, dict):
                    args = {"patch" if tool == "apply_patch" else "raw": args}
                if depth == "standard":
                    args = {key: value[:500] if isinstance(value, str) else value for key, value in args.items()}
                tools[call_id] = tool
                emit({"type": "tool_use", "tool": tool, "input": args, "at": end, "id": call_id})
            elif kind == "tool.execution_complete" and depth == "deep":
                call_id = data.get("toolCallId", "")
                result = data.get("result") or {}
                output = text(result.get("content")) if isinstance(result, dict) else text(result)
                error = data.get("error")
                if error and not output:
                    output = error.get("message", "") if isinstance(error, dict) else str(error)
                emit({"type": "tool_result", "tool": tools.get(call_id, "unknown"), "tool_use_id": call_id,
                      "text": output, "at": end, "is_error": data.get("success") is False})
    emit({"type": "session_end", "session_id": session_id, "ended_at": end, "event_count": count + 1})


def main():
    parser = argparse.ArgumentParser()
    subs = parser.add_subparsers(dest="command", required=True)
    subs.add_parser("list").add_argument("cwd")
    ex = subs.add_parser("extract")
    ex.add_argument("--session-id", required=True)
    ex.add_argument("--cwd", default="")
    ex.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    args = parser.parse_args()
    try:
        if args.command == "list":
            print(json.dumps(list_sessions(args.cwd)))
        else:
            extract(args.session_id, args.cwd, args.depth)
        return 0
    except (OSError, ValueError) as error:
        print(f"{os.environ.get('ATRIUM_COPILOT_METHOD', 'copilot')}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Gemini CLI session extractor — emits canonical JSONL events.

Maps Gemini's session JSON (ChatGenerateContentResponse shape) into the
canonical event stream.

Per architecture line 506: Gemini transcript format is UNSTABLE. On
parser failure this script emits ONLY session_start + session_end
(metadata-only degraded path) and exits 0 with a single stderr
warning. This is the silent-fallback approach chosen over declaring
supportsDepths:["quick"] — see Story 66.3 AC6.

Gemini session JSON typically looks like:
    {
      "sessionId": "...",
      "startTime": "...",
      "lastUpdated": "...",
      "messages": [
        {"type": "user", "content": [{"text": "..."}], "timestamp": "..."},
        {"type": "model", "content": [{"text": "..."}], "timestamp": "..."},
        {"type": "function", "functionCall": {"name":"...", "args":{...}}, "timestamp":"..."},
        {"type": "function", "functionResponse": {"name":"...","response":{...}}, ...}
      ]
    }
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ANSI_ESC = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")


def strip_ansi(text: str) -> str:
    return ANSI_ESC.sub("", text) if text else text


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=False))
    sys.stdout.write("\n")


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _flatten_content(content) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict):
            t = block.get("text") or ""
            if isinstance(t, str):
                parts.append(t)
        elif isinstance(block, str):
            parts.append(block)
    return "".join(parts)


def _truncate_title(text: str, max_len: int = 120) -> str:
    text = text.strip()
    return text if len(text) <= max_len else text[: max_len - 3] + "..."


def _degraded_path(session_id: str, cwd: str, started_at: str) -> None:
    """Emit metadata-only session_start + session_end and exit 0."""
    print("[gemini] transcript format not recognized; emitting metadata only", file=sys.stderr)
    emit({
        "type": "session_start",
        "session_id": session_id,
        "adapter": "gemini",
        "cwd": cwd,
        "started_at": started_at,
    })
    emit({
        "type": "session_end",
        "session_id": session_id,
        "ended_at": started_at,
        "event_count": 2,
    })


def extract(path: Path, session_id: str, cwd: str, depth: str) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"[gemini] parse failure: {exc}", file=sys.stderr)
        _degraded_path(session_id, cwd, iso_now())
        return

    if not isinstance(data, dict):
        _degraded_path(session_id, cwd, iso_now())
        return

    started_at = data.get("startTime") or data.get("lastUpdated") or iso_now()
    last_at = data.get("lastUpdated") or started_at
    messages = data.get("messages")
    if not isinstance(messages, list):
        _degraded_path(session_id, cwd, started_at)
        return

    first_user_text = None
    for m in messages:
        if isinstance(m, dict) and m.get("type") == "user":
            t = _flatten_content(m.get("content"))
            if t.strip():
                first_user_text = t.strip()
                break

    session_start = {
        "type": "session_start",
        "session_id": session_id,
        "adapter": "gemini",
        "cwd": cwd,
        "started_at": started_at,
    }
    if first_user_text:
        session_start["title"] = _truncate_title(first_user_text)
    emit(session_start)
    emitted = 1

    if depth == "quick":
        emit({
            "type": "session_end",
            "session_id": session_id,
            "ended_at": last_at,
            "event_count": emitted + 1,
        })
        return

    # Pass 2: messages → events
    saw_calls = {}  # call name → synthetic id
    call_counter = 0
    for m in messages:
        if not isinstance(m, dict):
            continue
        ts = m.get("timestamp") or iso_now()
        mtype = m.get("type")
        if mtype == "user":
            text = _flatten_content(m.get("content")).strip()
            if text:
                emit({"type": "prose", "role": "user", "text": text, "at": ts})
                emitted += 1
        elif mtype in ("model", "assistant"):
            text = _flatten_content(m.get("content")).strip()
            if text:
                emit({"type": "prose", "role": "assistant", "text": text, "at": ts})
                emitted += 1
        elif mtype == "function":
            fc = m.get("functionCall")
            fr = m.get("functionResponse")
            if isinstance(fc, dict):
                name = fc.get("name") or "unknown"
                args = fc.get("args") or {}
                if not isinstance(args, dict):
                    args = {"value": args}
                call_counter += 1
                call_id = f"call_{call_counter}"
                saw_calls[name] = call_id
                if depth == "standard":
                    args = {k: (v[:500] + "..." if isinstance(v, str) and len(v) > 500 else v) for k, v in args.items()}
                emit({"type": "tool_use", "tool": name, "input": args, "at": ts, "id": call_id})
                emitted += 1
            elif isinstance(fr, dict) and depth == "deep":
                name = fr.get("name") or "unknown"
                resp = fr.get("response")
                text = json.dumps(resp) if not isinstance(resp, str) else resp
                if name in {"shell", "Shell", "Bash", "Agent", "Task"}:
                    emit({
                        "type": "tool_result",
                        "tool": name,
                        "tool_use_id": saw_calls.get(name, ""),
                        "text": strip_ansi(text),
                        "at": ts,
                        "is_error": False,
                    })
                    emitted += 1

    emit({
        "type": "session_end",
        "session_id": session_id,
        "ended_at": last_at,
        "event_count": emitted + 1,
    })


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--transcript", required=True)
    p.add_argument("--session-id", required=True)
    p.add_argument("--adapter", default="gemini")
    p.add_argument("--cwd", default="")
    p.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    args = p.parse_args()

    transcript = Path(args.transcript)
    if not transcript.is_file():
        # In degraded path, still exit 0 with metadata-only emission so
        # the runner classifies as success (per AC6).
        _degraded_path(args.session_id, args.cwd, iso_now())
        return 0
    try:
        extract(transcript, args.session_id, args.cwd, args.depth)
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001
        # Silent fallback — never block the runner on Gemini format quirks.
        print(f"[gemini] degraded path (exception): {exc}", file=sys.stderr)
        _degraded_path(args.session_id, args.cwd, iso_now())
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

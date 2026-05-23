#!/usr/bin/env python3
"""Antigravity session extractor — emits canonical JSONL events.

Maps Antigravity's transcript JSONL into the canonical event stream.
Transcript line types: USER_INPUT, AGENT_RESPONSE, TOOL_CALL, TOOL_RESULT.

USER_INPUT content is wrapped in <USER_REQUEST>...</USER_REQUEST> tags;
we strip those for the user-facing prose.

Silent fallback (metadata-only emission) on parse failure, mirroring
Gemini's pattern.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ANSI_ESC = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
USER_REQUEST_RE = re.compile(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", re.DOTALL)


def strip_ansi(text: str) -> str:
    return ANSI_ESC.sub("", text) if text else text


def emit(event: dict) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=False))
    sys.stdout.write("\n")


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _truncate_title(text: str, max_len: int = 120) -> str:
    text = text.strip()
    return text if len(text) <= max_len else text[: max_len - 3] + "..."


def _degraded(session_id: str, cwd: str, ts: str) -> None:
    print("[antigravity] transcript format not recognized; emitting metadata only", file=sys.stderr)
    emit({
        "type": "session_start",
        "session_id": session_id,
        "adapter": "antigravity",
        "cwd": cwd,
        "started_at": ts,
    })
    emit({
        "type": "session_end",
        "session_id": session_id,
        "ended_at": ts,
        "event_count": 2,
    })


def _strip_user_request(text: str) -> str:
    m = USER_REQUEST_RE.search(text or "")
    if m:
        return m.group(1).strip()
    return text


def walk_transcript(path: Path):
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def extract(path: Path, session_id: str, cwd: str, depth: str) -> None:
    started_at = None
    last_at = None
    first_user_text = None

    for entry in walk_transcript(path):
        ts = entry.get("timestamp") or entry.get("at")
        if ts:
            if started_at is None:
                started_at = ts
            last_at = ts
        if first_user_text is None and entry.get("type") == "USER_INPUT":
            content = entry.get("content") or ""
            text = _strip_user_request(content).strip()
            if text:
                first_user_text = text

    if started_at is None:
        started_at = iso_now()
    if last_at is None:
        last_at = started_at

    session_start = {
        "type": "session_start",
        "session_id": session_id,
        "adapter": "antigravity",
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

    call_counter = 0
    pending_tool_ids = {}

    for entry in walk_transcript(path):
        ts = entry.get("timestamp") or entry.get("at") or iso_now()
        etype = entry.get("type")
        content = entry.get("content")

        if etype == "USER_INPUT":
            if isinstance(content, str):
                text = _strip_user_request(content).strip()
                if text:
                    emit({"type": "prose", "role": "user", "text": text, "at": ts})
                    emitted += 1
        elif etype == "AGENT_RESPONSE":
            if isinstance(content, str) and content.strip():
                emit({"type": "prose", "role": "assistant", "text": content.strip(), "at": ts})
                emitted += 1
        elif etype == "TOOL_CALL":
            tool_name = entry.get("name") or entry.get("tool") or "unknown"
            tool_input = entry.get("input") or entry.get("args") or content
            if isinstance(tool_input, str):
                try:
                    tool_input = json.loads(tool_input)
                except json.JSONDecodeError:
                    tool_input = {"raw": tool_input}
            if not isinstance(tool_input, dict):
                tool_input = {"value": tool_input}
            call_counter += 1
            call_id = entry.get("id") or entry.get("call_id") or f"call_{call_counter}"
            pending_tool_ids[tool_name] = call_id
            if depth == "standard":
                tool_input = {k: (v[:500] + "..." if isinstance(v, str) and len(v) > 500 else v) for k, v in tool_input.items()}
            emit({"type": "tool_use", "tool": tool_name, "input": tool_input, "at": ts, "id": call_id})
            emitted += 1
        elif etype == "TOOL_RESULT" and depth == "deep":
            tool_name = entry.get("name") or entry.get("tool") or "unknown"
            if tool_name not in {"Bash", "shell", "Shell", "Agent", "Task"}:
                continue
            text = entry.get("output") or content or ""
            if not isinstance(text, str):
                text = json.dumps(text)
            tool_use_id = entry.get("call_id") or entry.get("tool_use_id") or pending_tool_ids.get(tool_name, "")
            emit({
                "type": "tool_result",
                "tool": tool_name,
                "tool_use_id": tool_use_id,
                "text": strip_ansi(text),
                "at": ts,
                "is_error": bool(entry.get("is_error", False)),
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
    p.add_argument("--adapter", default="antigravity")
    p.add_argument("--cwd", default="")
    p.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    args = p.parse_args()

    transcript = Path(args.transcript)
    if not transcript.is_file():
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    try:
        extract(transcript, args.session_id, args.cwd, args.depth)
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001
        print(f"[antigravity] degraded path (exception): {exc}", file=sys.stderr)
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Codex (OpenAI) session extractor — emits canonical JSONL events.

Maps Codex's rollout JSONL into the canonical event stream defined by
../../schemas/canonical-event.schema.json.

Codex rollout file shape (first line is session_meta, rest are events):
    {"type":"session_meta","payload":{"id":...,"cwd":...,"timestamp":...}}
    {"type":"response_item","payload":{"role":"user","content":[...]}}
    {"type":"response_item","payload":{"role":"assistant","content":[...]}}
    {"type":"response_item","payload":{"type":"function_call","name":...,"arguments":...,"call_id":...}}
    {"type":"response_item","payload":{"type":"function_call_output","call_id":...,"output":...}}

We map:
    role:"user"   prose → prose{role:user}
    role:"assistant" prose → prose{role:assistant}
    function_call → tool_use{tool:name, input:args, id:call_id}
    function_call_output → tool_result{tool:?, tool_use_id:call_id, text:output}

Uses stdlib only.
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
    """Codex content is either a string or a list of {type, text}."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict):
            t = block.get("text") or block.get("content") or ""
            if isinstance(t, str):
                parts.append(t)
        elif isinstance(block, str):
            parts.append(block)
    return "".join(parts)


def _truncate_title(text: str, max_len: int = 120) -> str:
    text = text.strip()
    return text if len(text) <= max_len else text[: max_len - 3] + "..."


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


def _normalize_payload(entry):
    """Codex wraps events in {type, payload}; payload may be a string-encoded JSON."""
    payload = entry.get("payload", entry)
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except json.JSONDecodeError:
            payload = {}
    return payload


def extract(path: Path, session_id: str, adapter: str, cwd: str, depth: str):
    started_at = None
    last_at = None
    first_user_text = None
    saw_function_calls = {}  # call_id → tool name

    # Pass 1: metadata
    for entry in walk_transcript(path):
        ts = entry.get("timestamp") or entry.get("at")
        if ts:
            if started_at is None:
                started_at = ts
            last_at = ts
        payload = _normalize_payload(entry)
        if isinstance(payload, dict):
            etype = entry.get("type")
            if etype == "session_meta" and not started_at:
                started_at = payload.get("timestamp") or payload.get("started_at")
            if first_user_text is None:
                role = payload.get("role")
                if role == "user":
                    text = _flatten_content(payload.get("content"))
                    if text.strip():
                        first_user_text = text.strip()

    if started_at is None:
        started_at = iso_now()
    if last_at is None:
        last_at = started_at

    session_start = {
        "type": "session_start",
        "session_id": session_id,
        "adapter": adapter,
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

    # Pass 2: prose / tool_use / tool_result
    for entry in walk_transcript(path):
        ts = entry.get("timestamp") or entry.get("at") or iso_now()
        etype = entry.get("type")
        if etype == "session_meta":
            continue
        payload = _normalize_payload(entry)
        if not isinstance(payload, dict):
            continue

        # Detect shape. Order matters: function_call_output must be checked
        # before function_call (the substring match would otherwise miss-route).
        payload_type = payload.get("type")
        role = payload.get("role")

        if payload_type == "function_call_output" or role == "tool":
            call_id = payload.get("call_id") or payload.get("tool_call_id") or ""
            tool_name = saw_function_calls.get(call_id, payload.get("tool") or "unknown")
            output = payload.get("output") or payload.get("content") or ""
            if not isinstance(output, str):
                output = json.dumps(output)
            if depth == "deep":
                # Only emit tool_result at deep depth; restrict to Bash/Shell tools
                if tool_name in {"Bash", "shell", "Shell", "Agent", "Task"}:
                    emit({
                        "type": "tool_result",
                        "tool": tool_name,
                        "tool_use_id": call_id,
                        "text": strip_ansi(output),
                        "at": ts,
                        "is_error": bool(payload.get("is_error", False)),
                    })
                    emitted += 1

        elif payload_type == "function_call":
            tool_name = payload.get("name") or "unknown"
            args = payload.get("arguments")
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    args = {"raw": args}
            if not isinstance(args, dict):
                args = {"value": args}
            call_id = payload.get("call_id") or payload.get("id") or ""
            saw_function_calls[call_id] = tool_name
            if depth == "standard":
                compact = {}
                for k, v in args.items():
                    if isinstance(v, str) and len(v) > 500:
                        compact[k] = v[:500] + "..."
                    else:
                        compact[k] = v
                args = compact
            emit({
                "type": "tool_use",
                "tool": tool_name,
                "input": args,
                "at": ts,
                "id": call_id,
            })
            emitted += 1

        elif role == "user":
            text = _flatten_content(payload.get("content"))
            if text.strip():
                emit({
                    "type": "prose",
                    "role": "user",
                    "text": text.strip(),
                    "at": ts,
                })
                emitted += 1

        elif role == "assistant":
            text = _flatten_content(payload.get("content"))
            if text.strip():
                emit({
                    "type": "prose",
                    "role": "assistant",
                    "text": text.strip(),
                    "at": ts,
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
    p.add_argument("--adapter", required=True)
    p.add_argument("--cwd", default="")
    p.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    args = p.parse_args()

    transcript = Path(args.transcript)
    if not transcript.is_file():
        print(f"extract_session: transcript missing: {transcript}", file=sys.stderr)
        return 1
    try:
        extract(transcript, args.session_id, args.adapter, args.cwd, args.depth)
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001
        print(f"extract_session: parse error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

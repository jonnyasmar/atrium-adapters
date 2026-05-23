#!/usr/bin/env python3
"""OpenCode session extractor — emits canonical JSONL events.

Reads:
  - <project>/storage/session/info/ses_<id>.json (metadata)
  - <project>/storage/session/messages/<id>/<msg>.json (per-message JSON)

OpenCode's schema is informal — same silent-degradation safety net.
"""
from __future__ import annotations

import argparse
import json
import os
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


def _truncate_title(text: str, max_len: int = 120) -> str:
    text = text.strip()
    return text if len(text) <= max_len else text[: max_len - 3] + "..."


def _degraded(session_id: str, cwd: str, ts: str) -> None:
    print("[opencode] transcript format not recognized; emitting metadata only", file=sys.stderr)
    emit({
        "type": "session_start",
        "session_id": session_id,
        "adapter": "opencode",
        "cwd": cwd,
        "started_at": ts,
    })
    emit({
        "type": "session_end",
        "session_id": session_id,
        "ended_at": ts,
        "event_count": 2,
    })


def _normalize_ts(ts):
    if isinstance(ts, (int, float)):
        seconds = ts / 1000 if ts > 1e11 else ts
        return datetime.fromtimestamp(seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(ts, str) and ts:
        return ts
    return ""


def _flatten_content(content) -> str:
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


def extract(info_path: Path, messages_dir: str, session_id: str, cwd: str, depth: str) -> None:
    try:
        info = json.loads(info_path.read_text(encoding="utf-8", errors="replace"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"[opencode] info parse failure: {exc}", file=sys.stderr)
        _degraded(session_id, cwd, iso_now())
        return

    if not isinstance(info, dict):
        _degraded(session_id, cwd, iso_now())
        return

    time_block = info.get("time") or {}
    started_at = _normalize_ts(time_block.get("created") or info.get("created")) or iso_now()
    last_at = _normalize_ts(time_block.get("updated") or info.get("updated")) or started_at
    title = info.get("title") or info.get("name")

    session_start = {
        "type": "session_start",
        "session_id": session_id,
        "adapter": "opencode",
        "cwd": cwd,
        "started_at": started_at,
    }
    if title:
        session_start["title"] = _truncate_title(str(title))

    # Load messages
    messages = []
    if messages_dir and os.path.isdir(messages_dir):
        for entry in sorted(os.listdir(messages_dir)):
            if not entry.endswith(".json"):
                continue
            full = os.path.join(messages_dir, entry)
            try:
                with open(full, "r", encoding="utf-8", errors="replace") as f:
                    messages.append(json.load(f))
            except (json.JSONDecodeError, OSError):
                continue

    # If title still empty and messages exist, derive from first user msg
    if "title" not in session_start:
        for m in messages:
            if isinstance(m, dict) and m.get("role") == "user":
                t = _flatten_content(m.get("content") or m.get("text"))
                if t.strip():
                    session_start["title"] = _truncate_title(t.strip())
                    break

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
    for m in messages:
        if not isinstance(m, dict):
            continue
        ts = _normalize_ts(m.get("time") or m.get("createdAt") or m.get("timestamp")) or last_at
        if ts:
            last_at = ts
        role = m.get("role")

        if role == "user":
            text = _flatten_content(m.get("content") or m.get("text"))
            if text.strip():
                emit({"type": "prose", "role": "user", "text": text.strip(), "at": ts})
                emitted += 1
        elif role in ("assistant", "model"):
            text = _flatten_content(m.get("content") or m.get("text"))
            if text.strip():
                emit({"type": "prose", "role": "assistant", "text": text.strip(), "at": ts})
                emitted += 1
            # Tool calls embedded in message
            tool_calls = m.get("toolCalls") or m.get("tool_calls") or m.get("parts") or []
            if isinstance(tool_calls, list):
                for tc in tool_calls:
                    if not isinstance(tc, dict):
                        continue
                    if tc.get("type") not in (None, "tool_use", "tool_call", "tool-call"):
                        continue
                    call_counter += 1
                    tool_name = tc.get("name") or tc.get("tool") or "unknown"
                    args = tc.get("input") or tc.get("arguments") or tc.get("args") or {}
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {"raw": args}
                    if not isinstance(args, dict):
                        args = {"value": args}
                    call_id = tc.get("id") or tc.get("call_id") or f"call_{call_counter}"
                    if depth == "standard":
                        args = {k: (v[:500] + "..." if isinstance(v, str) and len(v) > 500 else v) for k, v in args.items()}
                    emit({"type": "tool_use", "tool": tool_name, "input": args, "at": ts, "id": call_id})
                    emitted += 1
        elif role == "tool" and depth == "deep":
            tool_name = m.get("tool") or m.get("name") or "unknown"
            if tool_name not in {"Bash", "shell", "Shell", "Agent", "Task"}:
                continue
            text = _flatten_content(m.get("content") or m.get("output") or m.get("text"))
            emit({
                "type": "tool_result",
                "tool": tool_name,
                "tool_use_id": m.get("tool_use_id") or m.get("tool_call_id") or "",
                "text": strip_ansi(text),
                "at": ts,
                "is_error": bool(m.get("is_error", False)),
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
    p.add_argument("--info", required=True)
    p.add_argument("--messages-dir", default="")
    p.add_argument("--session-id", required=True)
    p.add_argument("--adapter", default="opencode")
    p.add_argument("--cwd", default="")
    p.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    args = p.parse_args()

    info_path = Path(args.info)
    if not info_path.is_file():
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    try:
        extract(info_path, args.messages_dir, args.session_id, args.cwd, args.depth)
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001
        print(f"[opencode] degraded path (exception): {exc}", file=sys.stderr)
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

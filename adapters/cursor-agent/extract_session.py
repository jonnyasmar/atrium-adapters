#!/usr/bin/env python3
"""Cursor Agent session extractor — emits canonical JSONL events.

Opens Cursor's per-chat SQLite store.db read-only, queries the meta +
messages tables, and maps the message JSON blobs to canonical events.

Cursor's schema is informal — same silent-degradation safety net as
Gemini/Antigravity: on parse failure emit metadata-only and exit 0.

Stdlib only (sqlite3 is included on macOS + Debian/Ubuntu's python3).
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
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
    print("[cursor-agent] transcript format not recognized; emitting metadata only", file=sys.stderr)
    emit({
        "type": "session_start",
        "session_id": session_id,
        "adapter": "cursor-agent",
        "cwd": cwd,
        "started_at": ts,
    })
    emit({
        "type": "session_end",
        "session_id": session_id,
        "ended_at": ts,
        "event_count": 2,
    })


def _open_ro(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=0.5)


def _read_meta(conn: sqlite3.Connection) -> dict:
    """Cursor's meta table: row with key='0' has hex-encoded JSON blob."""
    try:
        row = conn.execute("SELECT value FROM meta WHERE key='0'").fetchone()
    except sqlite3.Error:
        return {}
    if not row or not row[0]:
        return {}
    try:
        return json.loads(bytes.fromhex(row[0]).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return {}


def _try_read_messages(conn: sqlite3.Connection):
    """Attempt to read messages table; tolerate schema variants."""
    # Cursor's schema has evolved; we try a few known shapes
    for sql in (
        "SELECT key, value FROM messages ORDER BY key",
        "SELECT id, payload FROM messages ORDER BY id",
        "SELECT key, value FROM kv WHERE key LIKE 'msg:%' ORDER BY key",
    ):
        try:
            return list(conn.execute(sql))
        except sqlite3.Error:
            continue
    return []


def _decode_message(value):
    """Cursor stores messages as hex-encoded JSON or plain JSON."""
    if value is None:
        return None
    if isinstance(value, bytes):
        try:
            value = value.decode("utf-8")
        except UnicodeDecodeError:
            return None
    if not isinstance(value, str):
        return None
    # Try hex-decoded JSON first
    try:
        if re.fullmatch(r"[0-9a-fA-F]+", value):
            return json.loads(bytes.fromhex(value).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        pass
    # Plain JSON
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return None


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


def extract(path: Path, session_id: str, cwd: str, depth: str) -> None:
    conn = _open_ro(path)
    try:
        meta = _read_meta(conn)
        started_at = ""
        if isinstance(meta, dict):
            ca = meta.get("createdAt")
            if isinstance(ca, (int, float)):
                seconds = ca / 1000 if ca > 1e11 else ca
                started_at = datetime.fromtimestamp(seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if not started_at:
            try:
                mt = path.stat().st_mtime
                started_at = datetime.fromtimestamp(mt, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            except OSError:
                started_at = iso_now()

        rows = _try_read_messages(conn)
        first_user_text = None
        decoded_messages = []
        for _key, value in rows:
            msg = _decode_message(value)
            if not isinstance(msg, dict):
                continue
            decoded_messages.append(msg)
            if first_user_text is None and msg.get("role") == "user":
                t = _flatten_content(msg.get("content") or msg.get("text"))
                if t.strip():
                    first_user_text = t.strip()

        if not decoded_messages:
            # Empty session — emit metadata-only but still exit 0
            session_start = {
                "type": "session_start",
                "session_id": session_id,
                "adapter": "cursor-agent",
                "cwd": cwd,
                "started_at": started_at,
            }
            if meta.get("name"):
                session_start["title"] = _truncate_title(str(meta["name"]))
            emit(session_start)
            emit({
                "type": "session_end",
                "session_id": session_id,
                "ended_at": started_at,
                "event_count": 2,
            })
            return

        session_start = {
            "type": "session_start",
            "session_id": session_id,
            "adapter": "cursor-agent",
            "cwd": cwd,
            "started_at": started_at,
        }
        title = first_user_text or (meta.get("name") if isinstance(meta, dict) else None)
        if title:
            session_start["title"] = _truncate_title(str(title))
        emit(session_start)
        emitted = 1

        if depth == "quick":
            emit({
                "type": "session_end",
                "session_id": session_id,
                "ended_at": started_at,
                "event_count": emitted + 1,
            })
            return

        last_at = started_at
        call_counter = 0
        for msg in decoded_messages:
            ts = msg.get("createdAt") or msg.get("timestamp") or msg.get("at") or last_at
            if isinstance(ts, (int, float)):
                seconds = ts / 1000 if ts > 1e11 else ts
                ts = datetime.fromtimestamp(seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            if isinstance(ts, str) and ts:
                last_at = ts

            role = msg.get("role") or msg.get("type")
            if role == "user":
                t = _flatten_content(msg.get("content") or msg.get("text"))
                if t.strip():
                    emit({"type": "prose", "role": "user", "text": t.strip(), "at": ts})
                    emitted += 1
            elif role in ("assistant", "model"):
                t = _flatten_content(msg.get("content") or msg.get("text"))
                if t.strip():
                    emit({"type": "prose", "role": "assistant", "text": t.strip(), "at": ts})
                    emitted += 1
                # Some assistant messages embed tool_calls
                tool_calls = msg.get("toolCalls") or msg.get("tool_calls") or []
                for tc in tool_calls if isinstance(tool_calls, list) else []:
                    if not isinstance(tc, dict):
                        continue
                    call_counter += 1
                    tool_name = tc.get("name") or "unknown"
                    args = tc.get("input") or tc.get("arguments") or {}
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {"raw": args}
                    if not isinstance(args, dict):
                        args = {"value": args}
                    call_id = tc.get("id") or f"call_{call_counter}"
                    if depth == "standard":
                        args = {k: (v[:500] + "..." if isinstance(v, str) and len(v) > 500 else v) for k, v in args.items()}
                    emit({"type": "tool_use", "tool": tool_name, "input": args, "at": ts, "id": call_id})
                    emitted += 1
            elif role == "tool" and depth == "deep":
                tool_name = msg.get("tool") or "unknown"
                if tool_name not in {"Bash", "shell", "Shell", "Agent", "Task"}:
                    continue
                text = _flatten_content(msg.get("content") or msg.get("output") or msg.get("text"))
                emit({
                    "type": "tool_result",
                    "tool": tool_name,
                    "tool_use_id": msg.get("tool_use_id") or msg.get("tool_call_id") or "",
                    "text": strip_ansi(text),
                    "at": ts,
                    "is_error": bool(msg.get("is_error", False)),
                })
                emitted += 1

        emit({
            "type": "session_end",
            "session_id": session_id,
            "ended_at": last_at,
            "event_count": emitted + 1,
        })
    finally:
        conn.close()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--transcript", required=True)
    p.add_argument("--session-id", required=True)
    p.add_argument("--adapter", default="cursor-agent")
    p.add_argument("--cwd", default="")
    p.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    args = p.parse_args()

    transcript = Path(args.transcript)
    if not transcript.is_file():
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    try:
        extract(transcript, args.session_id, args.cwd, args.depth)
    except sqlite3.Error as exc:
        print(f"[cursor-agent] sqlite error: {exc}", file=sys.stderr)
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001
        print(f"[cursor-agent] degraded path (exception): {exc}", file=sys.stderr)
        _degraded(args.session_id, args.cwd, iso_now())
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

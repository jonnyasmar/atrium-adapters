#!/usr/bin/env python3
"""Claude Code session extractor — emits canonical JSONL events.

Maps Anthropic-shaped transcript JSONL into the canonical event stream
defined by ../../schemas/canonical-event.schema.json. Walks the
transcript line-by-line; for each line, decides which canonical events
to emit based on the depth preset.

Depth presets:
    quick    — session_start + session_end (metadata only)
    standard — + prose + tool_use (with summary input)
    deep     — + tool_result for Bash/Agent only

Per architecture lines 274 / 489: tool_result emission is intentionally
restricted to Bash/Agent at deep depth because Read/Write/Edit/Grep/Glob
results are typically large file contents that bloat the FTS index
without adding much search-recall value.

Uses stdlib only (argparse, datetime, json, pathlib, re, sys).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ANSI_ESC = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
DEEP_TOOL_RESULT_ALLOWLIST = {"Bash", "Agent", "Task"}


def strip_ansi(text: str) -> str:
    """Remove ANSI escape sequences from tool output. See architecture line 274."""
    return ANSI_ESC.sub("", text) if text else text


def emit(event: dict) -> None:
    """Write one canonical event line to stdout."""
    sys.stdout.write(json.dumps(event, ensure_ascii=False))
    sys.stdout.write("\n")


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _coerce_at(value) -> str:
    """Coerce an Anthropic timestamp field to ISO-8601 string."""
    if isinstance(value, str) and value:
        return value
    return iso_now()


def _extract_text_blocks(message_content) -> str:
    """Flatten an Anthropic message content list into a single text blob.

    Anthropic content is either a string or a list of blocks each shaped
    {type: text|tool_use|tool_result, ...}. We collect text blocks here;
    tool_use / tool_result blocks are handled separately.
    """
    if isinstance(message_content, str):
        return message_content
    if not isinstance(message_content, list):
        return ""
    parts = []
    for block in message_content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            t = block.get("text", "")
            if isinstance(t, str):
                parts.append(t)
    return "".join(parts)


def _truncate_title(text: str, max_len: int = 120) -> str:
    text = text.strip()
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def walk_transcript(transcript_path: Path):
    """Yield raw transcript line dicts; tolerates malformed lines."""
    with transcript_path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                # Best-effort: skip malformed lines silently.
                continue


def extract(transcript_path: Path, session_id: str, adapter: str, cwd: str, depth: str):
    """Emit canonical events for the transcript at the given depth."""
    # Pass 1: scan for session_start metadata (first line typically), first user
    # message (for title), and final at-timestamp (for session_end).
    first_user_text = None
    started_at = None
    last_at = None
    line_count = 0

    for entry in walk_transcript(transcript_path):
        line_count += 1
        # Anthropic transcript top-level fields vary by line type:
        #   - {type: "user", message: {role, content}, timestamp, sessionId, cwd, ...}
        #   - {type: "assistant", message: {role, content}, timestamp, ...}
        #   - {type: "summary", ...}
        ts = entry.get("timestamp") or entry.get("at")
        if ts:
            if started_at is None:
                started_at = ts
            last_at = ts
        if first_user_text is None and entry.get("type") == "user":
            msg = entry.get("message") or {}
            content = msg.get("content") if isinstance(msg, dict) else None
            text = _extract_text_blocks(content)
            text = re.sub(r"<command-(name|message|args)>.*?</command-\1>", "", text, flags=re.DOTALL)
            text = text.strip()
            if text:
                first_user_text = text

    if started_at is None:
        started_at = iso_now()
    if last_at is None:
        last_at = started_at

    # Emit session_start
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

    # Quick depth = metadata only
    if depth == "quick":
        emit({
            "type": "session_end",
            "session_id": session_id,
            "ended_at": last_at,
            "event_count": emitted + 1,
        })
        return

    # Pass 2: walk again and emit prose / tool_use / tool_result.
    for entry in walk_transcript(transcript_path):
        entry_type = entry.get("type")
        msg = entry.get("message") or {}
        ts = entry.get("timestamp") or entry.get("at") or iso_now()
        content = msg.get("content") if isinstance(msg, dict) else None

        if entry_type == "user":
            # Prose-or-tool-result. If content is a list of tool_result blocks,
            # emit those; otherwise emit prose.
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "tool_result" and depth == "deep":
                        tool = block.get("tool") or "unknown"
                        # Tool name is on the upstream tool_use, not the result;
                        # but Anthropic doesn't carry it through, so we accept
                        # the synthetic "unknown" fallback unless the block
                        # itself includes it.
                        if tool not in DEEP_TOOL_RESULT_ALLOWLIST and tool != "unknown":
                            continue
                        text = block.get("content")
                        if isinstance(text, list):
                            text = _extract_text_blocks(text)
                        if not isinstance(text, str):
                            text = json.dumps(text) if text is not None else ""
                        emit({
                            "type": "tool_result",
                            "tool": tool,
                            "tool_use_id": block.get("tool_use_id") or "",
                            "text": strip_ansi(text),
                            "at": ts,
                            "is_error": bool(block.get("is_error", False)),
                        })
                        emitted += 1
                # Also emit any text content as prose
                text = _extract_text_blocks(content)
                text = re.sub(r"<command-(name|message|args)>.*?</command-\1>", "", text, flags=re.DOTALL).strip()
                if text:
                    emit({
                        "type": "prose",
                        "role": "user",
                        "text": text,
                        "at": ts,
                    })
                    emitted += 1
            else:
                text = _extract_text_blocks(content)
                text = re.sub(r"<command-(name|message|args)>.*?</command-\1>", "", text, flags=re.DOTALL).strip()
                if text:
                    emit({
                        "type": "prose",
                        "role": "user",
                        "text": text,
                        "at": ts,
                    })
                    emitted += 1

        elif entry_type == "assistant":
            # Walk content blocks: text → prose, tool_use → tool_use event
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type")
                    if btype == "text":
                        text = block.get("text", "")
                        if isinstance(text, str) and text.strip():
                            emit({
                                "type": "prose",
                                "role": "assistant",
                                "text": text,
                                "at": ts,
                            })
                            emitted += 1
                    elif btype == "tool_use":
                        tool_name = block.get("name") or "unknown"
                        tool_input = block.get("input") or {}
                        if not isinstance(tool_input, dict):
                            tool_input = {"value": tool_input}
                        # Standard depth: keep input compact; deep keeps full
                        if depth == "standard":
                            # Summarize commonly-large inputs
                            compact = {}
                            for k, v in tool_input.items():
                                if isinstance(v, str) and len(v) > 500:
                                    compact[k] = v[:500] + "..."
                                else:
                                    compact[k] = v
                            tool_input = compact
                        emit({
                            "type": "tool_use",
                            "tool": tool_name,
                            "input": tool_input,
                            "at": ts,
                            "id": block.get("id") or "",
                        })
                        emitted += 1
            elif isinstance(content, str) and content.strip():
                emit({
                    "type": "prose",
                    "role": "assistant",
                    "text": content,
                    "at": ts,
                })
                emitted += 1

    # Emit session_end
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

    transcript_path = Path(args.transcript)
    if not transcript_path.is_file():
        print(f"extract_session: transcript missing: {transcript_path}", file=sys.stderr)
        return 1

    try:
        extract(transcript_path, args.session_id, args.adapter, args.cwd, args.depth)
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    except Exception as exc:  # noqa: BLE001 — surface unexpected errors as parse error
        print(f"extract_session: parse error: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())

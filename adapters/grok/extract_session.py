#!/usr/bin/env python3
"""Grok Build session extractor — emits canonical JSONL events.

Maps `~/.grok/sessions/<encoded-cwd>/<session-id>/chat_history.jsonl`
(+ optional `summary.json` timestamps/title) into the canonical event
stream defined by ../../schemas/canonical-event.schema.json.

Depth presets:
    quick    — session_start + session_end (metadata only)
    standard — + prose + tool_use (compact input)
    deep     — + tool_result for shell/agent/search tools only

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ANSI_ESC = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
USER_QUERY_RE = re.compile(
    r"<user_query>\s*(.*?)\s*</user_query>",
    re.DOTALL | re.IGNORECASE,
)
# Large-result tools worth indexing at deep depth (shell, agents, search).
DEEP_TOOL_RESULT_ALLOWLIST = {
    "run_terminal_command",
    "bash",
    "Bash",
    "spawn_subagent",
    "Task",
    "Agent",
    "web_search",
    "web_fetch",
    "x_keyword_search",
    "x_semantic_search",
    "x_thread_fetch",
}


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


def _flatten_content(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                if block.get("type") == "text" and isinstance(block.get("text"), str):
                    parts.append(block["text"])
                elif isinstance(block.get("text"), str):
                    parts.append(block["text"])
        return "".join(parts)
    return str(content)


def _unwrap_user_query(text: str) -> str:
    """Prefer the inner <user_query> body when present (Grok wraps real prompts)."""
    if not text:
        return ""
    m = USER_QUERY_RE.search(text)
    if m:
        return m.group(1).strip()
    return text.strip()


def _is_synthetic_user(text: str) -> bool:
    """Skip context dumps that aren't real user prompts (title + prose noise)."""
    t = text.strip()
    if not t:
        return True
    # Pure harness wrappers with no user_query body.
    if t.startswith("<user_info>") and "<user_query>" not in t:
        return True
    if t.startswith("<system-reminder>") and "<user_query>" not in t:
        return True
    if t.startswith("<git_status>") and "<user_query>" not in t:
        return True
    return False


def _parse_args(raw) -> dict:
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {"value": parsed}
        except json.JSONDecodeError:
            return {"value": raw}
    return {"value": raw}


def _compact_input(tool_input: dict, depth: str) -> dict:
    if depth != "standard":
        return tool_input
    compact = {}
    for k, v in tool_input.items():
        if isinstance(v, str) and len(v) > 500:
            compact[k] = v[:500] + "..."
        else:
            compact[k] = v
    return compact


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


def _load_summary(summary_path: Path | None) -> dict:
    if not summary_path or not summary_path.is_file():
        return {}
    try:
        return json.loads(summary_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return {}


def extract(
    transcript_path: Path,
    session_id: str,
    adapter: str,
    cwd: str,
    depth: str,
    summary_path: Path | None = None,
):
    summary = _load_summary(summary_path)
    started_at = (
        summary.get("created_at")
        or (summary.get("info") or {}).get("created_at")
        or iso_now()
    )
    ended_at = (
        summary.get("last_active_at")
        or summary.get("updated_at")
        or started_at
    )
    title = (
        summary.get("generated_title")
        or summary.get("session_summary")
        or None
    )
    if isinstance(title, str):
        title = title.strip() or None

    # Pass 1: first real user prompt for title fallback + tool-name map for results.
    first_user = None
    tool_names: dict[str, str] = {}
    for entry in walk_transcript(transcript_path):
        et = entry.get("type")
        if et == "user" and first_user is None:
            text = _unwrap_user_query(_flatten_content(entry.get("content")))
            if text and not _is_synthetic_user(text):
                first_user = text
        elif et == "assistant":
            for tc in entry.get("tool_calls") or []:
                if not isinstance(tc, dict):
                    continue
                tid = tc.get("id")
                name = tc.get("name") or "unknown"
                if isinstance(tid, str) and tid:
                    tool_names[tid] = name
        elif et == "backend_tool_call":
            kind = entry.get("kind") or {}
            if isinstance(kind, dict):
                name = kind.get("tool_type") or "backend_tool"
                tid = entry.get("id") or entry.get("tool_call_id")
                if isinstance(tid, str) and tid:
                    tool_names[tid] = name

    if not title and first_user:
        title = _truncate_title(first_user)

    session_start = {
        "type": "session_start",
        "session_id": session_id,
        "adapter": adapter,
        "cwd": cwd,
        "started_at": started_at,
    }
    if title:
        session_start["title"] = _truncate_title(title)
    emit(session_start)
    emitted = 1

    if depth == "quick":
        emit({
            "type": "session_end",
            "session_id": session_id,
            "ended_at": ended_at,
            "event_count": emitted + 1,
        })
        return

    for entry in walk_transcript(transcript_path):
        et = entry.get("type")
        at = entry.get("timestamp") or entry.get("at") or ended_at

        if et == "user":
            text = _unwrap_user_query(_flatten_content(entry.get("content")))
            if text and not _is_synthetic_user(text):
                emit({
                    "type": "prose",
                    "role": "user",
                    "text": text,
                    "at": at,
                })
                emitted += 1

        elif et == "assistant":
            text = _flatten_content(entry.get("content"))
            if isinstance(text, str) and text.strip():
                emit({
                    "type": "prose",
                    "role": "assistant",
                    "text": text,
                    "at": at,
                })
                emitted += 1
            for tc in entry.get("tool_calls") or []:
                if not isinstance(tc, dict):
                    continue
                name = tc.get("name") or "unknown"
                tid = tc.get("id") or ""
                tool_input = _compact_input(_parse_args(tc.get("arguments")), depth)
                emit({
                    "type": "tool_use",
                    "tool": name,
                    "input": tool_input,
                    "at": at,
                    "id": tid,
                })
                emitted += 1
                if isinstance(tid, str) and tid:
                    tool_names[tid] = name

        elif et == "backend_tool_call":
            kind = entry.get("kind") or {}
            name = "backend_tool"
            tool_input: dict = {}
            if isinstance(kind, dict):
                name = kind.get("tool_type") or name
                action = kind.get("action")
                if isinstance(action, dict):
                    tool_input = _compact_input(action, depth)
                elif action is not None:
                    tool_input = {"action": action}
            tid = entry.get("id") or entry.get("tool_call_id") or f"backend-{emitted}"
            emit({
                "type": "tool_use",
                "tool": name,
                "input": tool_input,
                "at": at,
                "id": tid,
            })
            emitted += 1
            if isinstance(tid, str):
                tool_names[tid] = name

        elif et == "tool_result" and depth == "deep":
            tid = entry.get("tool_call_id") or ""
            tool = tool_names.get(tid, "unknown")
            if tool not in DEEP_TOOL_RESULT_ALLOWLIST and tool != "unknown":
                continue
            text = _flatten_content(entry.get("content"))
            if not isinstance(text, str):
                text = json.dumps(text) if text is not None else ""
            emit({
                "type": "tool_result",
                "tool": tool,
                "tool_use_id": tid,
                "text": strip_ansi(text),
                "at": at,
                "is_error": bool(entry.get("is_error", False)),
            })
            emitted += 1

        # system / reasoning — intentionally skipped

    emit({
        "type": "session_end",
        "session_id": session_id,
        "ended_at": ended_at,
        "event_count": emitted + 1,
    })


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--transcript", required=True)
    p.add_argument("--session-id", required=True)
    p.add_argument("--adapter", required=True)
    p.add_argument("--cwd", default="")
    p.add_argument("--depth", default="standard", choices=["quick", "standard", "deep"])
    p.add_argument("--summary", default="")
    args = p.parse_args()

    transcript_path = Path(args.transcript)
    if not transcript_path.is_file():
        print(f"extract_session: transcript missing: {transcript_path}", file=sys.stderr)
        return 1

    summary_path = Path(args.summary) if args.summary else None
    try:
        extract(
            transcript_path,
            args.session_id,
            args.adapter,
            args.cwd,
            args.depth,
            summary_path=summary_path,
        )
    except OSError as exc:
        print(f"extract_session: IO error: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())

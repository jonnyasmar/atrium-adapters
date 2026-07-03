#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Omp.
# Contract: see ../../schemas/canonical-event.schema.json
#
# Omp stores sessions as JSONL files under ~/.omp/agent/sessions/ (or
# $OMP_CODING_AGENT_SESSION_DIR / $PI_CODING_AGENT_SESSION_DIR if set),
# named `<ISO-timestamp>_<UUID>.jsonl` under per-cwd dash-encoded subdirs.
# File layout (session format v3):
#   {"type":"title","title":"..."}
#   {"type":"session","id":"<uuid>","cwd":"/abs/path","timestamp":...}
#   {"type":"message","timestamp":...,"message":{"role":"user"|"assistant"|"toolResult","content":[blocks]}}
# Assistant content blocks: text | thinking | toolCall{id,name,arguments}.
# toolResult messages carry toolCallId, toolName, isError, content.

SESSION_ID=""
CWD=""
DEPTH="standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --cwd)        CWD="$2";        shift 2 ;;
    --depth)      DEPTH="$2";      shift 2 ;;
    *) echo "extract_session: unknown arg $1" >&2; exit 10 ;;
  esac
done

if [[ -z "$SESSION_ID" ]]; then
  echo "extract_session: --session-id required" >&2
  exit 10
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "extract_session: python3 required" >&2
  exit 3
fi

TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.jsonl" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.jsonl"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  ROOT="${OMP_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_SESSION_DIR:-${HOME}/.omp/agent/sessions}}"
  if [[ ! -d "$ROOT" ]]; then
    echo "extract_session: omp sessions root not found: $ROOT" >&2
    exit 1
  fi
  CANDIDATE=$(find "$ROOT" -name "*${SESSION_ID}.jsonl" -print -quit 2>/dev/null || true)
  if [[ -n "$CANDIDATE" ]]; then
    TRANSCRIPT="$CANDIDATE"
  fi
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: omp transcript not found for $SESSION_ID" >&2
  exit 1
fi

exec python3 - "$TRANSCRIPT" "$SESSION_ID" "$CWD" "$DEPTH" <<'PY'
import json, re, sys
from datetime import datetime, timezone

transcript = sys.argv[1]
session_id = sys.argv[2]
cwd = sys.argv[3]
depth = sys.argv[4] if len(sys.argv) > 4 else "standard"

ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
RESULT_TOOLS = {"bash", "shell", "agent", "task"}


def strip_ansi(t):
    return ANSI.sub("", t) if t else t


def emit(ev):
    sys.stdout.write(json.dumps(ev, ensure_ascii=False))
    sys.stdout.write("\n")


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _trunc(t, n=120):
    t = t.strip()
    return t if len(t) <= n else t[: n - 3] + "..."


def _flatten(content, kinds=("text",)):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for b in content:
        if isinstance(b, dict):
            if b.get("type") in kinds:
                t = b.get("text") or b.get("content") or ""
                if isinstance(t, str):
                    parts.append(t)
        elif isinstance(b, str):
            parts.append(b)
    return "".join(parts)


def _norm_ts(ts):
    if isinstance(ts, (int, float)):
        seconds = ts / 1000 if ts > 1e11 else ts
        return datetime.fromtimestamp(seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(ts, str) and ts:
        return ts
    return None


def _degraded(sid, cwd, ts):
    print("[omp] transcript format not recognized; emitting metadata only", file=sys.stderr)
    emit({"type": "session_start", "session_id": sid, "adapter": "omp", "cwd": cwd, "started_at": ts})
    emit({"type": "session_end", "session_id": sid, "ended_at": ts, "event_count": 2})


def walk(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


try:
    started_at = None
    last_at = None
    title = ""
    first_user = None
    entries = list(walk(transcript))

    for e in entries:
        ts = _norm_ts(e.get("timestamp") or e.get("at") or e.get("createdAt"))
        if ts:
            if started_at is None:
                started_at = ts
            last_at = ts
        kind = e.get("type")
        if kind in ("title", "title_change"):
            t = e.get("title") or ""
            if isinstance(t, str) and t.strip():
                title = t.strip()
        elif kind == "session":
            if not cwd:
                cwd = e.get("cwd") or ""
        elif kind == "message":
            m = e.get("message")
            if first_user is None and isinstance(m, dict) and m.get("role") == "user":
                t = _flatten(m.get("content"))
                if t.strip():
                    first_user = t.strip()

    if started_at is None:
        started_at = iso_now()
    if last_at is None:
        last_at = started_at

    ss = {"type": "session_start", "session_id": session_id, "adapter": "omp", "cwd": cwd, "started_at": started_at}
    if title or first_user:
        ss["title"] = _trunc(title or first_user)
    emit(ss)
    emitted = 1

    if depth == "quick":
        emit({"type": "session_end", "session_id": session_id, "ended_at": last_at, "event_count": emitted + 1})
        sys.exit(0)

    call_counter = 0
    for e in entries:
        if e.get("type") != "message":
            continue
        m = e.get("message")
        if not isinstance(m, dict):
            continue
        ts = _norm_ts(e.get("timestamp") or m.get("timestamp")) or last_at
        role = m.get("role")
        if role == "user":
            t = _flatten(m.get("content"))
            if t.strip():
                emit({"type": "prose", "role": "user", "text": t.strip(), "at": ts})
                emitted += 1
        elif role == "assistant":
            t = _flatten(m.get("content"))
            if t.strip():
                emit({"type": "prose", "role": "assistant", "text": t.strip(), "at": ts})
                emitted += 1
            content = m.get("content")
            if isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict) or b.get("type") != "toolCall":
                        continue
                    call_counter += 1
                    tool = b.get("name") or "unknown"
                    args = b.get("arguments") or {}
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {"raw": args}
                    if not isinstance(args, dict):
                        args = {"value": args}
                    cid = b.get("id") or f"call_{call_counter}"
                    if depth == "standard":
                        args = {k: (v[:500] + "..." if isinstance(v, str) and len(v) > 500 else v) for k, v in args.items()}
                    emit({"type": "tool_use", "tool": tool, "input": args, "at": ts, "id": cid})
                    emitted += 1
        elif role == "toolResult" and depth == "deep":
            tool = m.get("toolName") or "unknown"
            if tool.lower() not in RESULT_TOOLS:
                continue
            text = _flatten(m.get("content"))
            emit({
                "type": "tool_result",
                "tool": tool,
                "tool_use_id": m.get("toolCallId") or "",
                "text": strip_ansi(text),
                "at": ts,
                "is_error": bool(m.get("isError", False)),
            })
            emitted += 1

    emit({"type": "session_end", "session_id": session_id, "ended_at": last_at, "event_count": emitted + 1})
except OSError as exc:
    print(f"extract_session: IO error: {exc}", file=sys.stderr)
    sys.exit(3)
except Exception as exc:
    print(f"[omp] degraded path (exception): {exc}", file=sys.stderr)
    _degraded(session_id, cwd, iso_now())
    sys.exit(0)
PY

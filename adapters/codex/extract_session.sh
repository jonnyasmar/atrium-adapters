#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Codex.
# Contract: see ../../schemas/canonical-event.schema.json
#
# Codex stores rollout files at:
#   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
# First line is {type: "session_meta", payload: {id, cwd, timestamp, ...}}.
# Subsequent lines are OpenAI-shaped {type, role|function_call|..., content, ...}.
#
# Env: ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY — overrides
#      the production ~/.codex/sessions transcript root).

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

# Resolve a runnable Python 3 into PYTHON. On Windows `python3` is often the
# Microsoft Store app-execution alias (...\Microsoft\WindowsApps\python3): it
# exists but runs nothing, while python.org and conda installs answer to
# `python` or the `py -3` launcher. Inline rather than in ../shared: sourcing
# that costs two subshells per call on Windows.
find_python() {
  local name path
  for name in python3 python py; do
    hash "$name" 2>/dev/null || continue
    path="$name"
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
      path="${BASH_CMDS[$name]:-$name}"
      shopt -s nocasematch
      case "$path" in
        */microsoft/windowsapps/*)
          shopt -u nocasematch
          continue
          ;;
      esac
      shopt -u nocasematch
    fi
    PYTHON=("$path")
    [ "$name" != py ] || PYTHON+=(-3)
    return 0
  done
  return 1
}

if ! find_python; then
  echo "extract_session: no runnable Python 3 (tried python3, python, py -3)" >&2
  exit 3
fi

SESSIONS_ROOT="${ATRIUM_TEST_TRANSCRIPT_ROOT:-${HOME}/.codex/sessions}"
if [[ ! -d "$SESSIONS_ROOT" ]]; then
  echo "extract_session: codex sessions root not found: $SESSIONS_ROOT" >&2
  exit 1
fi

# Find the rollout file whose session_meta.payload.id matches SESSION_ID.
# In fixture mode, the fixture-session.jsonl directly contains the session.
TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "$SESSIONS_ROOT/fixture-session.jsonl" ]] && [[ -f "$SESSIONS_ROOT/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "$SESSIONS_ROOT/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="$SESSIONS_ROOT/fixture-session.jsonl"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  # Production: walk date-partitioned rollout files, match by session_meta.payload.id
  TRANSCRIPT=$("${PYTHON[@]}" - "$SESSIONS_ROOT" "$SESSION_ID" <<'PY' 2>/dev/null || true
import glob, json, os, sys
root, session_id = sys.argv[1], sys.argv[2]
for path in sorted(glob.glob(os.path.join(root, "*/*/*/rollout-*.jsonl")), reverse=True):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            first = f.readline()
        meta = json.loads(first)
        if meta.get("type") != "session_meta":
            continue
        payload = meta.get("payload")
        if isinstance(payload, str):
            payload = json.loads(payload)
        if isinstance(payload, dict) and payload.get("id") == session_id:
            print(path)
            sys.exit(0)
    except (json.JSONDecodeError, OSError, KeyError):
        continue
PY
)
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: session not found: $SESSION_ID" >&2
  exit 1
fi

exec "${PYTHON[@]}" "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter codex \
  --cwd "$CWD" \
  --depth "$DEPTH"

#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Claude Code.
# Contract: see ../../schemas/canonical-event.schema.json
# Architecture: atrium repo _bmad-output/planning-artifacts/architecture-adapter-session-fts.md§"Per-Adapter Extraction Contract"
#
# Args: --session-id <id> --cwd <path> --depth <quick|standard|deep>
# Env:  ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY — overrides the production
#       ~/.claude/projects transcript root)
#
# Exit codes: 0=ok, 1=source-not-found, 2=parse-error, 3=IO error
#   (e.g. python3 missing), >=10=usage/fatal.

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

# CI fixture override; production uses ~/.claude/projects
CC_ROOT="${ATRIUM_TEST_TRANSCRIPT_ROOT:-${HOME}/.claude/projects}"
if [[ ! -d "$CC_ROOT" ]]; then
  echo "extract_session: claude projects root not found: $CC_ROOT" >&2
  exit 1
fi

# Find session transcript JSONL. In production, walks .claude/projects/<encoded>/<id>.jsonl;
# in fixture mode, the fixture-session.jsonl is the transcript IF the requested
# session id matches the id pinned in fixture-session-id.txt (this gates the
# AC11 "exit 1 for not-found" contract under fixture isolation).
TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "$CC_ROOT/fixture-session.jsonl" ]] && [[ -f "$CC_ROOT/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "$CC_ROOT/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="$CC_ROOT/fixture-session.jsonl"
  fi
elif [[ -f "$CC_ROOT/${SESSION_ID}.jsonl" ]]; then
  TRANSCRIPT="$CC_ROOT/${SESSION_ID}.jsonl"
else
  TRANSCRIPT=$(find "$CC_ROOT" -name "${SESSION_ID}.jsonl" -print -quit 2>/dev/null || true)
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: session not found: $SESSION_ID" >&2
  exit 1
fi

exec "${PYTHON[@]}" "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter claude-code \
  --cwd "$CWD" \
  --depth "$DEPTH"

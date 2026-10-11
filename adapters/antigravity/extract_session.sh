#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Antigravity (agy).
# Contract: see ../../schemas/canonical-event.schema.json
#
# Antigravity stores per-session transcripts at:
#   ~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl
#
# Env: ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY).

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

TRANSCRIPT=""
if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.jsonl" ]] && [[ -f "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="${ATRIUM_TEST_TRANSCRIPT_ROOT}/fixture-session.jsonl"
  fi
elif [[ -z "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]]; then
  AGY_BRAIN="${HOME}/.gemini/antigravity-cli/brain/${SESSION_ID}/.system_generated/logs/transcript.jsonl"
  if [[ -f "$AGY_BRAIN" ]]; then
    TRANSCRIPT="$AGY_BRAIN"
  fi
  # Fallback: scan known antigravity roots for any path containing
  # the SESSION_ID (handles future layout changes + cases where the
  # brain dir is split across roots).
  if [[ -z "$TRANSCRIPT" ]]; then
    for ROOT in "${HOME}/.gemini/antigravity-cli" \
                "${HOME}/.antigravity" \
                "${HOME}/Library/Application Support/Antigravity"; do
      [[ -d "$ROOT" ]] || continue
      CANDIDATE=$(find "$ROOT" -type f \( -name "transcript.jsonl" -o -name "*.jsonl" \) -path "*${SESSION_ID}*" -print -quit 2>/dev/null || true)
      if [[ -n "$CANDIDATE" ]]; then
        TRANSCRIPT="$CANDIDATE"
        break
      fi
    done
  fi
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: antigravity transcript not found for $SESSION_ID" >&2
  exit 1
fi

exec "${PYTHON[@]}" "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter antigravity \
  --cwd "$CWD" \
  --depth "$DEPTH"

#!/usr/bin/env bash
set -euo pipefail

# extract_session.sh — Emit canonical session events for Grok Build.
# Contract: see ../../schemas/canonical-event.schema.json
#
# Args: --session-id <id> --cwd <path> --depth <quick|standard|deep>
# Env:  ATRIUM_TEST_TRANSCRIPT_ROOT (FOR CI FIXTURE TESTING ONLY — overrides
#       the production ~/.grok/sessions root)
#
# Production layout:
#   ~/.grok/sessions/<url-encoded-cwd>/<session-uuid>/chat_history.jsonl
#   ~/.grok/sessions/<url-encoded-cwd>/<session-uuid>/summary.json
#
# Exit codes: 0=ok, 1=source-not-found, 2=parse-error, 3=IO error, >=10=usage.

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
  echo "extract_session: python3 required (install python3 on this system)" >&2
  exit 3
fi

GROK_ROOT="${ATRIUM_TEST_TRANSCRIPT_ROOT:-${HOME}/.grok/sessions}"
TRANSCRIPT=""
SUMMARY=""

if [[ -n "${ATRIUM_TEST_TRANSCRIPT_ROOT:-}" ]] \
  && [[ -f "$GROK_ROOT/fixture-session.jsonl" ]] \
  && [[ -f "$GROK_ROOT/fixture-session-id.txt" ]]; then
  FIXTURE_ID=$(tr -d '[:space:]' < "$GROK_ROOT/fixture-session-id.txt")
  if [[ "$SESSION_ID" == "$FIXTURE_ID" ]]; then
    TRANSCRIPT="$GROK_ROOT/fixture-session.jsonl"
    if [[ -f "$GROK_ROOT/fixture-summary.json" ]]; then
      SUMMARY="$GROK_ROOT/fixture-summary.json"
    fi
  fi
elif [[ -d "$GROK_ROOT" ]]; then
  # Prefer cwd-encoded path when CWD is known; fall back to a find by session id.
  if [[ -n "$CWD" ]]; then
    ENCODED="$(printf '%s' "$CWD" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))' 2>/dev/null || true)"
    if [[ -z "$ENCODED" ]]; then
      ENCODED="${CWD//\//%2F}"
    fi
    candidate="$GROK_ROOT/${ENCODED}/${SESSION_ID}/chat_history.jsonl"
    if [[ -f "$candidate" ]]; then
      TRANSCRIPT="$candidate"
      if [[ -f "$GROK_ROOT/${ENCODED}/${SESSION_ID}/summary.json" ]]; then
        SUMMARY="$GROK_ROOT/${ENCODED}/${SESSION_ID}/summary.json"
      fi
    fi
  fi

  if [[ -z "$TRANSCRIPT" ]]; then
    # Glob: ~/.grok/sessions/*/<session-id>/chat_history.jsonl
    for candidate in "$GROK_ROOT"/*/"$SESSION_ID"/chat_history.jsonl; do
      if [[ -f "$candidate" ]]; then
        TRANSCRIPT="$candidate"
        sum_candidate="$(dirname "$candidate")/summary.json"
        if [[ -f "$sum_candidate" ]]; then
          SUMMARY="$sum_candidate"
        fi
        break
      fi
    done
  fi
fi

if [[ -z "$TRANSCRIPT" ]] || [[ ! -f "$TRANSCRIPT" ]]; then
  echo "extract_session: session not found: $SESSION_ID" >&2
  exit 1
fi

SUMMARY_ARG=()
if [[ -n "$SUMMARY" ]] && [[ -f "$SUMMARY" ]]; then
  SUMMARY_ARG=(--summary "$SUMMARY")
fi

exec python3 "$(dirname "$0")/extract_session.py" \
  --transcript "$TRANSCRIPT" \
  --session-id "$SESSION_ID" \
  --adapter grok \
  --cwd "$CWD" \
  --depth "$DEPTH" \
  "${SUMMARY_ARG[@]}"

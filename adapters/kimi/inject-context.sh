#!/usr/bin/env bash
set -uo pipefail

MODE="${1:-inject}"
PAYLOAD="$(cat 2>/dev/null || true)"

if [[ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]] \
  || [[ -z "${ATRIUM:-}" ]] \
  || [[ -z "${ATRIUM_PANE_ID:-}" ]] \
  || ! command -v jq >/dev/null 2>&1; then
  [[ "$MODE" == "inject" ]] && printf '{}\n'
  exit 0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(cd "$DIR/../.." 2>/dev/null && pwd || printf '%s' "$HOME/.atrium")"
case "$(basename "$DATA_DIR")" in
  .atrium-dev*) DEFAULT_CLI="$DATA_DIR/bin/atrium-dev" ;;
  *) DEFAULT_CLI="$DATA_DIR/bin/atrium" ;;
esac
ATRIUM_CLI="${ATRIUM_CLI_PATH:-$DEFAULT_CLI}"
[[ -x "$ATRIUM_CLI" ]] || ATRIUM_CLI="atrium"

session_id="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf unknown)"
marker_key="${ATRIUM_PANE_ID}-${session_id}"
marker_key="${marker_key//[^A-Za-z0-9_.-]/_}"
MARKER="${TMPDIR:-/tmp}/atrium-kimi-context-${marker_key}"

case "$MODE" in
  --reset|--cleanup)
    rm -f "$MARKER"
    exit 0
    ;;
esac

parts=""
append() {
  [[ -n "$1" ]] || return 0
  if [[ -n "$parts" ]]; then
    parts="${parts}"$'\n\n'"$1"
  else
    parts="$1"
  fi
}

fetch_pipeline_context() {
  local event="$1" port response
  command -v curl >/dev/null 2>&1 || return 0
  [[ -f "$DATA_DIR/hook-port" ]] || return 0
  port="$(<"$DATA_DIR/hook-port")"
  [[ -n "$port" ]] || return 0
  response="$(curl -fsS \
    --connect-timeout 1 \
    --max-time 2 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Atrium-Pane-Id: ${ATRIUM_PANE_ID}" \
    --data-binary "$PAYLOAD" \
    "http://127.0.0.1:${port}/api/adapter/kimi/${event}" 2>/dev/null || true)"
  printf '%s' "$response" | jq -r '.atriumContext // empty' 2>/dev/null || true
}

if [[ ! -f "$MARKER" ]]; then
  manifest="$("$ATRIUM_CLI" skills resolve-manifest \
    --pane-id "$ATRIUM_PANE_ID" --adapter kimi 2>/dev/null || true)"
  case "$manifest" in
    *"ATRIUM CONTEXT MANIFEST"*) append "$manifest" ;;
  esac
  append "$(fetch_pipeline_context session-start)"
  : >"$MARKER"
fi

append "$(fetch_pipeline_context user-prompt-submit)"

sigils="$(printf '%s' "$PAYLOAD" \
  | "$ATRIUM_CLI" skills resolve-prompt-sigils \
      --pane-id "$ATRIUM_PANE_ID" --adapter kimi 2>/dev/null \
  | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
append "$sigils"

if [[ -n "$parts" ]]; then
  jq -n --arg message "$parts" '{message: $message}'
else
  printf '{}\n'
fi
exit 0

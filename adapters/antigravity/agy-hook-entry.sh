#!/usr/bin/env bash
# agy-hook-entry.sh — single entry point for every atrium hook agy fires.
#
# WHY A SCRIPT AND NOT AN INLINE COMMAND (2026-09-07):
#   The agy CLI (Go) runs hook commands through a shell, so an inline
#   one-liner worked. The Antigravity ACP SERVER (Python) does not — it
#   splits the command on whitespace and execs argv directly. An inline
#   command therefore fails with
#     hooks.py:84 Failed to run hook command '...'
#     hooks.py:768 External hook 'atrium' failed to execute.
#   and, because PreToolUse treats missing stdout as DENY, every single
#   tool call in an ACP chat session is blocked. Verified by driving the
#   real ACP server: with an inline command the tool is denied; with this
#   script the same prompt runs `echo` and returns exit_code 0.
#
#   A bare `<path> <event>` command works under BOTH (a shell runs it
#   fine; bare exec splits it into argv correctly), so this is the only
#   shape compatible with the CLI and the ACP server at once.
#
# Usage: agy-hook-entry.sh <session-start|pre-tool-use|post-tool-use|stop>
#
# Contract per event is agy's, not atrium's:
#   PreToolUse  stdout MUST be {"decision":"allow"} or the call is denied.
#   Stop/PostToolUse stdout {} .
#   PreInvocation stdout is an optional injectSteps envelope.
# Every path exits 0 — a non-zero exit is also treated as a denial.

set -uo pipefail

EVENT="${1:-}"

# The hook config is global, so this also runs for agy sessions with no atrium
# pane (started outside atrium). Nothing can be attributed there: answer agy's
# per-event contract and skip the jq, normalizer and CLI spawns.
if [ -z "${ATRIUM_PANE_ID:-}" ]; then
  case "$EVENT" in
    post-tool-use | session-start | stop) printf '{}\n' ;;
    *) printf '{"decision":"allow"}\n' ;;
  esac
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Self-locating defaults: this script lives at <data-dir>/adapters/antigravity,
# so the data dir is two levels up. Runtime env still wins when agy passes it
# through; the derived value covers the sanitized-env case.
DERIVED_DATA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="${ATRIUM_DATA_DIR:-$DERIVED_DATA_DIR}"

resolve_cli() {
  if [ -n "${ATRIUM_CLI_PATH:-}" ] && [ -x "${ATRIUM_CLI_PATH}" ]; then
    printf '%s' "$ATRIUM_CLI_PATH"
    return
  fi
  # The channel's binary is named after it (atrium, atrium-dev, atrium-beta);
  # there is exactly one in the data dir's bin/.
  local candidate
  for candidate in "$DATA_DIR"/bin/*; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return
    fi
  done
  printf '%s' "atrium"
}
CLI="$(resolve_cli)"
NORMALIZE="$SCRIPT_DIR/normalize-hook-payload.sh"
LOG_FILE="/tmp/atrium-agy-hooks.log"

log() {
  [ "${ATRIUM_HOOK_DEBUG:-1}" = "0" ] && return 0
  printf '[%s] [pane=%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ATRIUM_PANE_ID:-?}" "$*" \
    >>"$LOG_FILE" 2>/dev/null || true
}

emit() {
  # $1 = atrium event name; stdin = agy payload
  local event="$1"
  "$NORMALIZE" "$event" \
    | "$CLI" hook emit "$event" --adapter antigravity \
        --pane-id "${ATRIUM_PANE_ID:-}" --json >/dev/null 2>>"$LOG_FILE"
  log "$event emit rc=$?"
}

payload="$(cat 2>/dev/null || true)"
log "$EVENT stdin=$(printf '%s' "$payload" | head -c 400)"

case "$EVENT" in
  pre-tool-use)
    printf '%s' "$payload" | emit pre-tool-use
    # agy denies the tool call unless it sees an explicit allow.
    printf '{"decision":"allow"}\n'
    ;;

  post-tool-use)
    printf '%s' "$payload" | emit post-tool-use
    printf '{}\n'
    ;;

  session-start)
    # PreInvocation fires for EVERY model call, so a single user turn
    # produces several. session-start is idempotent atrium-side, but
    # user-prompt-submit means "new turn" and clears recentToolCalls —
    # emitting it on a continuation wipes tool history mid-turn.
    inv="$(printf '%s' "$payload" | jq -r '.invocationNum // 0' 2>/dev/null || echo 0)"
    printf '%s' "$payload" | emit session-start
    if [ "$inv" = "0" ] || [ "$inv" = "1" ]; then
      printf '%s' "$payload" | emit user-prompt-submit
    else
      log "user-prompt-submit suppressed (continuation invocation inv=$inv)"
    fi
    # inject-context.sh owns stdout here: it emits agy's injectSteps
    # envelope on the first invocation and {} otherwise.
    printf '%s' "$payload" \
      | ATRIUM_CLI_PATH="$CLI" ATRIUM_DATA_DIR="$DATA_DIR" \
        "$SCRIPT_DIR/inject-context.sh" 2>>"$LOG_FILE"
    log "inject rc=$?"
    ;;

  stop)
    # Stop fires after every tool-execution sub-loop; only `fullyIdle`
    # marks the turn genuinely finished. Without the gate the activity
    # card bounces between active and waiting several times per turn.
    idle="$(printf '%s' "$payload" | jq -r '.fullyIdle // false' 2>/dev/null || echo false)"
    log "stop fullyIdle=$idle"
    if [ "$idle" = "true" ]; then
      printf '%s' "$payload" | emit stop
    fi
    printf '{}\n'
    ;;

  *)
    log "unknown event '$EVENT'"
    # Unknown event on the PreToolUse path would deny the call, so stay
    # permissive: an atrium bug must not brick the user's agent.
    printf '{"decision":"allow"}\n'
    ;;
esac

exit 0

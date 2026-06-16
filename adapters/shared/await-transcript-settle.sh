#!/usr/bin/env bash
# await-transcript-settle.sh — wait for an agent's final assistant reply to be
# flushed to its session transcript before a stop-hook normalizer scrapes it.
#
# WHY (the "last assistant message is one turn behind" bug):
#   Several agent CLIs fire their stop / turn-end hook a few hundred milliseconds
#   BEFORE the turn's final assistant message is written to the session log.
#   Verified for claude-code by instrumenting the live Stop hook: at fire-time
#   the transcript held ONLY the user prompt — both the thinking block and the
#   text reply (whose in-file timestamps were already in the past) landed on disk
#   afterward. So a scrape at fire-time returns the PREVIOUS turn's reply (or
#   empty on turn one) — consistently "one behind".
#
#   The fix is timing-tolerant, not timing-dependent: poll a per-format
#   "final reply present" predicate until it passes, bounded by a small budget
#   well under the 5s hook timeout. When the reply is already on disk (no race)
#   the predicate passes on the first check and we return immediately, so this
#   adds no latency to the common case.
#
# USAGE:
#   await-transcript-settle.sh <mode> <path> [budget_ms] [interval_ms]
#       Poll until the predicate passes or the budget elapses. Always exits 0
#       (best effort — the caller scrapes whatever is on disk regardless).
#   await-transcript-settle.sh --check <mode> <path>
#       Evaluate the predicate once and print "true"/"false". For unit tests.
#
#   <mode>: claude | grok   (wired into those stop normalizers today)
#           antigravity      (predicate provided but NOT yet wired — agy's
#                            transcript turn-end shape isn't verified against a
#                            real session, and a wrong "final reply present"
#                            check would add constant latency. Wire it once a
#                            real agy transcript confirms the predicate.)
#
# The predicate reads the transcript TAIL (bounded, so a long log never threatens
# the hook timeout) and reports whether the last conversation line is the turn's
# final assistant reply. While the reply lags, the last line is the user prompt
# or a tool result, so the predicate stays false and we keep waiting.

set -u

# Per-format jq predicate. Run with `jq -rR --slurp` over the newline-joined
# transcript tail; prints "true" once the final reply is present.
predicate_for() {
  case "$1" in
    claude)
      # claude-code JSONL: each turn is user/assistant lines; tool results are
      # themselves type=="user". Settled when the LAST user|assistant line
      # (metadata/attachment lines ignored) is an assistant turn with non-empty
      # text — i.e. the reply, not a trailing tool_result or the bare prompt.
      cat <<'JQ'
split("\n") | map(select(. != "") | (fromjson? // empty))
| map(select(.type == "user" or .type == "assistant"))
| last
| ((.type == "assistant")
   and ((.message.content // []) | type == "array")
   and ((.message.content // []) | any(.type == "text" and ((.text // "") | length) > 0)))
| if . == true then "true" else "false" end
JQ
      ;;
    grok)
      # grok chat_history.jsonl: {"type":"assistant"|"user"|"system","content":"…"}.
      # Settled when the last assistant|user line is a non-empty assistant reply.
      cat <<'JQ'
split("\n") | map(select(. != "") | (fromjson? // empty))
| map(select(.type == "assistant" or .type == "user"))
| last
| ((.type == "assistant") and ((.content // "") | type == "string") and ((.content // "") | length > 0))
| if . == true then "true" else "false" end
JQ
      ;;
    antigravity)
      # agy transcript.jsonl: model turns are
      # {"type":"PLANNER_RESPONSE","source":"MODEL","content":"…"}. We only know
      # the model-turn shape, so the predicate is conservative: settled when the
      # LAST non-empty parseable line is a non-empty MODEL response. If agy writes
      # other trailing line types this can over-wait (safe — never wrong).
      cat <<'JQ'
split("\n") | map(select(. != "") | (fromjson? // empty)) | last
| ((.type == "PLANNER_RESPONSE") and (.source == "MODEL") and ((.content // "") | length > 0))
| if . == true then "true" else "false" end
JQ
      ;;
    *) printf '' ;;
  esac
}

run_check() {
  local mode="$1" path="$2" pred
  pred="$(predicate_for "$mode")"
  if [ -z "$pred" ] || [ ! -f "$path" ] || ! command -v jq >/dev/null 2>&1; then
    printf 'false'
    return
  fi
  tail -n 800 "$path" 2>/dev/null | jq -rR --slurp "$pred" 2>/dev/null || printf 'false'
}

if [ "${1:-}" = "--check" ]; then
  run_check "${2:-}" "${3:-}"
  exit 0
fi

mode="${1:-}"
path="${2:-}"
budget_ms="${3:-2000}"
interval_ms="${4:-120}"

[ -n "$mode" ] && [ -n "$path" ] && [ -f "$path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "$interval_ms" -gt 0 ] 2>/dev/null || interval_ms=120

attempts=$(( budget_ms / interval_ms ))
[ "$attempts" -ge 1 ] || attempts=1
sleep_s="$(awk "BEGIN{printf \"%.3f\", $interval_ms/1000}" 2>/dev/null || echo 0.12)"

i=0
while [ "$i" -lt "$attempts" ]; do
  [ "$(run_check "$mode" "$path")" = "true" ] && exit 0
  sleep "$sleep_s" 2>/dev/null || true
  i=$(( i + 1 ))
done
exit 0

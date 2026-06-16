#!/usr/bin/env bash
# normalize-hook-payload.sh — Claude Code adapter.
#
# Reads Claude's native hook payload from stdin, enriches it per event,
# and writes the augmented payload to stdout.
#
# Argument: $1 = atrium event name (post-tool-use | stop). When $1 is
# empty it defaults to `post-tool-use` for backward compatibility with
# legacy installed hooks that piped through this script with no arg —
# those only ever ran on PostToolUse.
#
# post-tool-use:
#   Claude PostToolUse payload shape:
#     { tool_name: "Edit"|"MultiEdit"|"Write"|...,
#       tool_input: { file_path: "...", ... } }
#   Enriched with the `_atrium` write-attribution envelope
#   (see ../../HOOK_ENVELOPE.md). Non-write tools pass through unchanged.
#
# stop:
#   Claude Stop payload carries `transcript_path` (a JSONL file). Each
#   assistant turn is a line shaped like:
#     {"type":"assistant","message":{"role":"assistant",
#       "content":[{"type":"text","text":"..."},{"type":"tool_use",...}]}}
#   We surface the LAST assistant message with non-empty text content as
#   `last_assistant_message` so the agent's final reply reaches both the
#   activity card and the timeline. The scan is bounded to the file tail
#   so a long transcript never threatens the 5s hook timeout. Before scraping
#   we wait (../shared/await-transcript-settle.sh) for the reply to be flushed
#   — Claude fires Stop before the final message lands, which otherwise yields
#   the previous turn's reply ("one behind").
#
# Any other event passes through verbatim — atrium only reads the
# normalized fields on the events above.
#
# Fail-safe: if jq fails for any reason, the original payload is written
# verbatim so atrium's legacy fallback extraction still fires. pipefail
# without `-e` (matches the grok adapter): a benign nonzero exit from
# jq-in-a-subshell must not abort the stop case mid-enrichment.

set -uo pipefail

EVENT="${1:-post-tool-use}"
input="$(cat)"

case "$EVENT" in
  post-tool-use)
    enriched="$(
      printf '%s' "$input" | jq -c '
        . as $p
        | (.tool_name // "") as $tool
        | (.tool_input // {}) as $ti
        | (
            if $tool == "Edit" then
              {
                writeKind: "edit",
                filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
                lineStart: null,
                lineEnd: null
              }
            elif $tool == "MultiEdit" then
              {
                writeKind: "multi-edit",
                filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
                lineStart: null,
                lineEnd: null
              }
            elif $tool == "Write" then
              {
                writeKind: "write",
                filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
                lineStart: null,
                lineEnd: null
              }
            else
              null
            end
          ) as $atrium
        | if ($atrium != null) and (($atrium.filePaths // []) | length > 0) then
            $p + {_atrium: $atrium}
          else
            $p
          end
      ' 2>/dev/null || true
    )"

    if [ -n "$enriched" ]; then
      printf '%s' "$enriched"
    else
      printf '%s' "$input"
    fi
    ;;

  stop)
    transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    last_msg=""
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
      # Claude fires this Stop hook a few hundred ms BEFORE the turn's final
      # assistant message is flushed to the transcript (verified: at fire-time
      # only the user prompt is on disk), so scraping immediately yields the
      # PREVIOUS turn's reply — "one behind". Wait for the reply to land first.
      settle="$(dirname "$0")/../shared/await-transcript-settle.sh"
      [ -x "$settle" ] && "$settle" claude "$transcript_path"

      # Read only the last ~800 lines, then reverse so the first
      # text-bearing assistant turn we hit is the most recent one.
      # tail -r is reverse on BSD/macOS; fall back to an awk reverse
      # for portability where -r is unavailable.
      if tail -r </dev/null >/dev/null 2>&1; then
        reversed="$(tail -n 800 "$transcript_path" 2>/dev/null | tail -r 2>/dev/null || true)"
      else
        reversed="$(tail -n 800 "$transcript_path" 2>/dev/null | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' 2>/dev/null || true)"
      fi
      last_msg="$(printf '%s' "$reversed" | jq -rR --slurp '
        split("\n")
        | map(select(. != "") | (fromjson? // empty))
        | map(select(.type == "assistant"))
        | map((.message.content // []) | map(select(.type == "text") | .text) | join("\n"))
        | map(select(length > 0))
        | first // empty
        | .[0:4000]
      ' 2>/dev/null || true)"
    fi

    if [ -n "$last_msg" ]; then
      printf '%s' "$input" | jq -c --arg m "$last_msg" '. + {last_assistant_message: $m}' 2>/dev/null || printf '%s' "$input"
    else
      printf '%s' "$input"
    fi
    ;;

  *)
    printf '%s' "$input"
    ;;
esac

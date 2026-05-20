#!/usr/bin/env bash
# normalize-hook-payload.sh — Antigravity (agy) adapter.
#
# Reads agy's native hook stdin, rewrites it into atrium's canonical
# field shape, and emits the augmented payload to stdout.
#
# Argument: $1 = atrium event name (pre-tool-use, post-tool-use,
#                user-prompt-submit, session-start). Drives event-specific
#                augmentations (e.g. user-prompt-submit reads the latest
#                history.jsonl entry for the prompt text).
#
# Field remapping (every event):
#   agy.conversationId   →  session_id            (atrium key for session lookup)
#
# Per-event augmentations:
#   pre-tool-use:
#     agy.toolCall.name  →  tool_name             (atrium activity card)
#     agy.toolCall.args  →  tool_input            (stringified if object)
#     _atrium envelope (HOOK_ENVELOPE.md write-attribution)
#   post-tool-use:
#     agy.error          →  error                 (already matches)
#     (PostToolUse stdin has NO toolCall; atrium's activity card uses
#      the PreToolUse-set tool name and just transitions on post.)
#   user-prompt-submit:
#     Latest history.jsonl `display` text  →  user_prompt
#     (PreInvocation stdin doesn't carry the user prompt text. The
#      agy history.jsonl file is appended on every prompt with
#      {display, timestamp, workspace}, so the last line is the
#      current prompt.)
#   session-start:
#     (session_id is the only remap; atrium uses it to call
#      list_recent_sessions for the session name.)

set -euo pipefail

EVENT="${1:-}"
HISTORY_FILE="${HOME}/.gemini/antigravity-cli/history.jsonl"

input="$(cat)"

# Base transform: alias conversationId → session_id on every event.
base="$(
  printf '%s' "$input" | jq -c '
    . as $p
    | (.conversationId // "") as $cid
    | if $cid != "" then ($p + {session_id: $cid}) else $p end
  ' 2>/dev/null || printf '%s' "$input"
)"

case "$EVENT" in
  pre-tool-use)
    # Add tool_name + tool_input + _atrium envelope.
    printf '%s' "$base" | jq -c '
      . as $p
      | (.toolCall.name // "") as $tool
      | (.toolCall.args // {}) as $args
      | (
          if $tool != "" then
            {
              tool_name: $tool,
              tool_input: ($args | tojson)
            }
          else
            {}
          end
        ) as $tool_fields
      | (
          if $tool == "write_to_file" then
            {
              writeKind: "write",
              filePaths: ([$args.TargetFile] | map(select(type == "string" and length > 0))),
              lineStart: null,
              lineEnd: null
            }
          elif $tool == "replace_file_content" then
            {
              writeKind: "edit",
              filePaths: ([$args.TargetFile] | map(select(type == "string" and length > 0))),
              lineStart: ($args.StartLine // null),
              lineEnd: ($args.EndLine // null)
            }
          elif $tool == "multi_replace_file_content" then
            {
              writeKind: "multi-edit",
              filePaths: ([$args.TargetFile] | map(select(type == "string" and length > 0))),
              lineStart: null,
              lineEnd: null
            }
          else
            null
          end
        ) as $atrium
      | $p + $tool_fields
        + (if ($atrium != null) and (($atrium.filePaths // []) | length > 0) then {_atrium: $atrium} else {} end)
    ' 2>/dev/null || printf '%s' "$base"
    ;;
  post-tool-use)
    # PostToolUse has no toolCall in agy; just forward with session_id alias.
    printf '%s' "$base"
    ;;
  user-prompt-submit)
    # Try to pull the latest user prompt text from history.jsonl.
    if [ -f "$HISTORY_FILE" ]; then
      prompt_text="$(tail -n 1 "$HISTORY_FILE" 2>/dev/null | jq -r '.display // empty' 2>/dev/null || true)"
    else
      prompt_text=""
    fi
    if [ -n "$prompt_text" ]; then
      printf '%s' "$base" | jq -c --arg p "$prompt_text" '. + {user_prompt: $p, prompt: $p}' 2>/dev/null || printf '%s' "$base"
    else
      printf '%s' "$base"
    fi
    ;;
  stop)
    # Atrium clears recentToolCalls when stop fires; to keep the
    # activity card informative, surface the model's final reply as
    # last_assistant_message. agy's hook stdin doesn't carry it, but
    # the transcript.jsonl referenced by `transcriptPath` does:
    # the last `{"type":"PLANNER_RESPONSE","source":"MODEL"}` entry
    # with non-empty content is the model's final answer for this turn.
    transcript_path="$(printf '%s' "$base" | jq -r '.transcriptPath // empty' 2>/dev/null || true)"
    last_msg=""
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
      # Walk the tail for the most recent non-empty PLANNER_RESPONSE.
      # tail -r is reverse on BSD/macOS; fall back to awk if missing.
      if command -v tail >/dev/null && tail -r </dev/null >/dev/null 2>&1; then
        last_msg="$(tail -r "$transcript_path" 2>/dev/null \
          | jq -rR 'fromjson? // empty | select(.type == "PLANNER_RESPONSE" and .source == "MODEL" and ((.content // "") | length) > 0) | .content' 2>/dev/null \
          | head -n 1)"
      else
        last_msg="$(awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$transcript_path" 2>/dev/null \
          | jq -rR 'fromjson? // empty | select(.type == "PLANNER_RESPONSE" and .source == "MODEL" and ((.content // "") | length) > 0) | .content' 2>/dev/null \
          | head -n 1)"
      fi
    fi
    if [ -n "$last_msg" ]; then
      printf '%s' "$base" | jq -c --arg m "$last_msg" '. + {last_assistant_message: $m}' 2>/dev/null || printf '%s' "$base"
    else
      printf '%s' "$base"
    fi
    ;;
  session-start|*)
    # Base transform is sufficient.
    printf '%s' "$base"
    ;;
esac

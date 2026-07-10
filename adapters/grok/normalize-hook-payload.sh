#!/usr/bin/env bash
# normalize-hook-payload.sh — Grok adapter.
#
# Grok hook payloads use camelCase keys (`sessionId`, `toolName`,
# `toolInput`, `toolResult`, `prompt`, `workspaceRoot`, …) — confirmed
# against real hook stdin captured in atrium's /_state endpoint:
#   pre_tool_use     : sessionId, toolName, toolInput, toolUseId, …
#   post_tool_use    : sessionId, toolName, toolInput, toolResult, …
#   user_prompt_submit: sessionId, prompt, promptId, …
#   session_start    : sessionId, source, cwd, …
#   stop             : sessionId, cwd/workspaceRoot, …
#
# Atrium's activity-card reducer reads snake_case (`session_id`,
# `tool_name`, `tool_input`, `tool_response`, `user_prompt`) and
# filters out tool entries whose `tool_name` is missing — so without
# this remap the card shows "session present, no tool calls, no
# response".
#
# Argument: $1 = atrium event name. Stdin: native grok payload.
# Stdout: atrium-shaped payload (snake_case, with PostToolUse write-
# attribution envelope and Stop transcript-scrape for
# last_assistant_message).
#
# Fail-safe: if jq fails, the original payload is emitted verbatim so
# atrium's fallback extraction still fires.

set -uo pipefail

EVENT="${1:-}"
input="$(cat)"

# Base remap applied to every event. Aliases camelCase grok keys onto
# atrium-side snake_case keys, strips grok's `<user_query>…</user_query>`
# wrapper from the prompt (grok always wraps; atrium's "last user
# prompt" line would otherwise render the literal tags). Preserves
# the originals (some downstream consumers still read camelCase) and
# tolerates missing fields per-event.
base="$(
  printf '%s' "$input" | jq -c '
    . as $p
    # Strip the <user_query>...</user_query> wrapper grok always adds
    # around the user prompt. Non-greedy regex, no extended mode, with
    # the trailing ? suppressing the no-match error so events without a
    # .prompt field (every event except user_prompt_submit) pass clean.
    | (
        (.prompt // "") as $raw
        | ($raw | capture("^<user_query>[[:space:]]*(?<inner>(.|\\n)*?)[[:space:]]*</user_query>[[:space:]]*$")? // null) as $m
        | (if $m == null then $raw else $m.inner end)
      ) as $unwrapped_prompt
    | (
        (if has("sessionId")     then {session_id:        .sessionId}     else {} end) +
        (if has("workspaceRoot") then {workspace_root:    .workspaceRoot} else {} end) +
        (if has("toolName")      then {tool_name:         .toolName}      else {} end) +
        (if has("toolInput")     then {tool_input:        (.toolInput     | if type == "string" then . else tojson end)} else {} end) +
        (if has("toolResult")    then {tool_response:     (.toolResult    | if type == "string" then . else tojson end)} else {} end) +
        (if has("toolUseId")     then {tool_use_id:       .toolUseId}     else {} end) +
        (if has("prompt")        then {user_prompt:       $unwrapped_prompt, prompt: $unwrapped_prompt} else {} end) +
        (if has("promptId")      then {prompt_id:         .promptId}      else {} end) +
        (if has("transcriptPath") then {transcript_path:  .transcriptPath} else {} end)
      ) as $aliases
    | $p + $aliases
  ' 2>/dev/null || printf '%s' "$input"
)"

case "$EVENT" in
  post-tool-use|post-tool-use-failure)
    enriched="$(printf '%s' "$base" | jq -c --arg event "$EVENT" '
      . as $p
      | (.tool_name // "") as $tool
      # tool_input may be a JSON string (from base remap of camelCase
      # input) or an object (when the fixture is already snake_case).
      # Parse-or-pass-through into an object for the file-path lookup.
      | (.tool_input // .toolInput // {}) as $ti_raw
      | (if ($ti_raw | type) == "object" then $ti_raw else ($ti_raw | fromjson? // {}) end) as $ti
      | (
          if ($tool == "edit_file" or $tool == "search_replace" or $tool == "Edit") then
            {
              writeKind: "edit",
              filePaths: ([$ti.file_path // $ti.target_file // $ti.path // $ti.file] | map(select(type == "string" and length > 0))),
              lineStart: null,
              lineEnd: null
            }
          elif ($tool == "write_file" or $tool == "create_file" or $tool == "Write") then
            {
              writeKind: "write",
              filePaths: ([$ti.file_path // $ti.target_file // $ti.path // $ti.file] | map(select(type == "string" and length > 0))),
              lineStart: null,
              lineEnd: null
            }
          elif ($tool == "MultiEdit") then
            {
              writeKind: "multi-edit",
              filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
              lineStart: null,
              lineEnd: null
            }
          else
            null
          end
        ) as $atrium
      | (if $event == "post-tool-use-failure" then
          {
            error: (
              .error
              // .message
              // .reason
              // (if (.tool_response // .toolResult // null) != null
                  then (.tool_response // .toolResult | if type == "string" then . else tojson end)
                  else "tool failed"
                 end)
            )
          }
        else
          {}
        end) as $fail
      | $p + $fail
      | if ($atrium != null) and (($atrium.filePaths // []) | length > 0) then
          . + {_atrium: $atrium}
        else
          .
        end
    ' 2>/dev/null || printf '%s' "$base")"
    printf '%s' "$enriched"
    ;;

  stop)
    # Grok writes chat history at:
    #   ~/.grok/sessions/<url-encoded-cwd>/<session_id>/chat_history.jsonl
    # Each line is {"type":"assistant"|"user"|"system","content":"…"}.
    # We want the LAST assistant message's content as plain text.
    session_id="$(printf '%s' "$base" | jq -r '.session_id // empty' 2>/dev/null)"
    cwd="$(printf '%s' "$base" | jq -r '.cwd // .workspace_root // .workspaceRoot // empty' 2>/dev/null)"

    chat_path="$(printf '%s' "$base" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)"
    if [ -n "$chat_path" ] && [ ! -f "$chat_path" ]; then
      chat_path=""
    fi

    if [ -z "$chat_path" ] && [ -n "$session_id" ] && [ -n "$cwd" ]; then
      encoded="$(printf '%s' "$cwd" | perl -MURI::Escape -e 'print uri_escape(<STDIN>);' 2>/dev/null || true)"
      [ -z "$encoded" ] && encoded="${cwd//\//%2F}"
      candidate="${HOME}/.grok/sessions/${encoded}/${session_id}/chat_history.jsonl"
      [ -f "$candidate" ] && chat_path="$candidate"
    fi

    last_msg=""
    if [ -n "$chat_path" ] && [ -f "$chat_path" ]; then
      # Wait for this turn's reply to be flushed before scraping — same
      # "stop fires before the final message lands" race fixed for claude-code
      # (the hook can otherwise read the previous turn's reply, "one behind").
      settle="$(dirname "$0")/../shared/await-transcript-settle.sh"
      [ -x "$settle" ] && "$settle" grok "$chat_path"
      last_msg="$(tail -r "$chat_path" 2>/dev/null | jq -rR --slurp '
        split("\n")
        | map(select(. != "") | fromjson?)
        | map(select(.type == "assistant" and (.content | type == "string") and (.content | length > 0)))
        | first
        | .content // empty
      ' 2>/dev/null || true)"
    fi

    if [ -n "$last_msg" ]; then
      enriched="$(printf '%s' "$base" | jq -c --arg msg "$last_msg" '. + {last_assistant_message: $msg}' 2>/dev/null || printf '%s' "$base")"
      printf '%s' "$enriched"
    else
      printf '%s' "$base"
    fi
    ;;

  *)
    printf '%s' "$base"
    ;;
esac

#!/usr/bin/env bash
set -uo pipefail

EVENT="${1:-}"
INPUT="$(cat)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$EVENT" in
  user-prompt-submit)
    printf '%s' "$INPUT" | jq -c '
      (.prompt // "") as $native
      | (
          if ($native | type) == "array" then
            [$native[] | select(.type == "text") | (.text // "")] | join("\n")
          elif ($native | type) == "string" then $native
          else ""
          end
        ) as $prompt
      | . + {prompt: $prompt, user_prompt: $prompt}
    ' 2>/dev/null || printf '%s' "$INPUT"
    ;;

  pre-tool-use|post-tool-use|post-tool-use-failure)
    printf '%s' "$INPUT" | jq -c --arg event "$EVENT" '
      . as $payload
      | (.tool_input // {}) as $tool_input
      | (
          if ($tool_input | type) == "string" then $tool_input
          else ($tool_input | tojson)
          end
        ) as $tool_input_text
      | $payload + {
          tool_input: $tool_input_text,
          tool_input_json: $tool_input
        }
      | if $event == "post-tool-use" then
          . + {tool_response: (.tool_output // "")}
        elif $event == "post-tool-use-failure" then
          . + {
            tool_response: "",
            error: (
              if (.error | type) == "object" then (.error.message // (.error | tojson))
              elif (.error | type) == "string" then .error
              else "tool failed"
              end
            )
          }
        else .
        end
      | (.tool_name // "") as $tool
      | (
          $tool_input.file_path
          // $tool_input.path
          // $tool_input.filePath
          // ""
        ) as $path
      | if ($event == "post-tool-use")
          and ($path | type == "string" and length > 0)
          and ($tool == "Write" or $tool == "Edit" or $tool == "MultiEdit"
               or $tool == "write_file" or $tool == "edit_file") then
          . + {
            _atrium: {
              writeKind: (
                if $tool == "Edit" or $tool == "edit_file" then "edit"
                elif $tool == "MultiEdit" then "multi-edit"
                else "write"
                end
              ),
              filePaths: [$path],
              lineStart: null,
              lineEnd: null
            }
          }
        else .
        end
    ' 2>/dev/null || printf '%s' "$INPUT"
    ;;

  stop)
    transcript_path="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    if [[ -n "$transcript_path" && "$transcript_path" != /* ]]; then
      transcript_path="$DIR/$transcript_path"
    fi

    if [[ -z "$transcript_path" ]]; then
      session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
      index_path="${KIMI_CODE_HOME:-$HOME/.kimi-code}/session_index.jsonl"
      if [[ -n "$session_id" && -f "$index_path" ]]; then
        session_dir="$(jq -rs --arg id "$session_id" '
          reduce .[] as $record ({};
            if $record.sessionId == $id and $record.deleted == true then del(.[$id])
            elif $record.sessionId == $id then .[$id] = $record
            else .
            end
          )
          | .[$id].sessionDir // empty
        ' "$index_path" 2>/dev/null || true)"
        [[ -n "$session_dir" ]] && transcript_path="$session_dir/agents/main/wire.jsonl"
      fi
    fi

    last_message=""
    if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
      last_message="$(tail -n 4000 "$transcript_path" 2>/dev/null \
        | jq -r '
            select(
              .type == "context.append_loop_event"
              and .event.type == "content.part"
              and .event.part.type == "text"
              and ((.event.part.text // "") | length > 0)
            )
            | .event.part.text
          ' 2>/dev/null \
        | tail -n 1 \
        | head -c 4000 || true)"
    fi

    if [[ -n "$last_message" ]]; then
      printf '%s' "$INPUT" | jq -c --arg message "$last_message" \
        '. + {last_assistant_message: $message}' 2>/dev/null || printf '%s' "$INPUT"
    else
      printf '%s' "$INPUT"
    fi
    ;;

  stop-failure)
    printf '%s' "$INPUT" | jq -c '
      . + {
        reason: (.error_type // "error"),
        error: (.error_message // .error_type // "Kimi stopped with an error")
      }
    ' 2>/dev/null || printf '%s' "$INPUT"
    ;;

  interrupt)
    printf '%s' "$INPUT" | jq -c '. + {reason: (.reason // "interrupt")}' 2>/dev/null \
      || printf '%s' "$INPUT"
    ;;

  *)
    printf '%s' "$INPUT"
    ;;
esac

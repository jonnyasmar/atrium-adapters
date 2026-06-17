#!/usr/bin/env bash
# normalize-hook-payload.sh — Hermes adapter.
#
# Translate Hermes's shell-hook stdin payload into atrium's hook contract.
# Usage: normalize-hook-payload.sh <atrium-event>   (payload on stdin -> stdout)
#
# Hermes payload (agent/shell_hooks.py::_serialize_payload):
#   { hook_event_name, tool_name, tool_input(obj|null),
#     session_id, cwd, extra{...} }
#
# atrium wants `tool_input` as a JSON-STRINGIFIED string, and pulls the
# remaining fields out of `extra`:
#   user-prompt-submit : user_prompt           <- extra.user_message
#   post-tool-use      : tool_response          <- extra.result
#                        error                  <- extra.error_message
#   stop               : last_assistant_message <- extra.assistant_response
EVENT="${1:?Usage: normalize-hook-payload.sh <atrium-event>}"
input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  # No jq: pass through. session_id / tool_name already match atrium's names;
  # tool_input won't be stringified, but the card still renders.
  printf '%s' "$input"
  exit 0
fi

out="$(printf '%s' "$input" | jq -c --arg ev "$EVENT" '
  . as $p
  | {session_id: (($p.session_id // "") | tostring)}
  + (if $ev == "pre-tool-use" or $ev == "post-tool-use" then
       { tool_name: (($p.tool_name // "") | tostring),
         tool_input: (($p.tool_input // {}) | tojson) }
     else {} end)
  + (if $ev == "post-tool-use" then
       ( (if ($p.extra.result != null)
          then { tool_response: ($p.extra.result | if type == "string" then . else tojson end) }
          else {} end)
       + (if (($p.extra.error_message // "") | tostring) != ""
          then { error: ($p.extra.error_message | tostring) }
          else {} end) )
     else {} end)
  + (if $ev == "user-prompt-submit" then
       { user_prompt: (($p.extra.user_message // "") | tostring) }
     else {} end)
  + (if $ev == "stop" then
       { last_assistant_message: (($p.extra.assistant_response // "") | tostring) }
     else {} end)
' 2>/dev/null)"

if [ -n "$out" ]; then
  printf '%s' "$out"
else
  printf '%s' "$input"
fi

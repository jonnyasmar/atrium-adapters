#!/usr/bin/env bash
set -euo pipefail

state="$(cat)"

jq -e '
  ([.events[] | select(.eventName == "user-prompt-submit")] | last
    | .payload.user_prompt == "Please inspect the adapter.")
  and
  ([.events[] | select(.eventName == "post-tool-use")] | last
    | .payload._atrium.filePaths == ["/tmp/kimi-adapter.txt"])
  and
  ([.events[] | select(.eventName == "stop")] | last
    | .payload.last_assistant_message == "Kimi adapter smoke complete.")
  and
  ([.events[] | select(.eventName == "permission-request")] | last
    | .payload.tool_name == "Bash")
' <<<"$state" >/dev/null

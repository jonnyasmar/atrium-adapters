#!/usr/bin/env bash
set -euo pipefail

SESSION_ID="${1:?Usage: build_resume_command.sh <session-id> [flags-json]}"
FLAGS="${2:-"{}"}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

jq -cn --arg session "$SESSION_ID" --argjson flags "$FLAGS" \
  --arg trustSh "${ADAPTER_DIR}/trust-workspace.sh" '
  def extra_args:
    ($flags.extraArgs // "")
    | if type != "string" then "" else . end
    | gsub("^\\s+|\\s+$"; "")
    | if length == 0 then [] else split(" ") | map(select(length > 0)) end;
  (
    # See build_launch_command.sh — the trust gate quits on Enter, so a
    # resumed pane needs the same pre-trust wrapper.
    (if $flags.trust == true then [$trustSh] else [] end)
    + (if (($flags.effort // "") | type == "string" and length > 0)
     then ["env", ("KIMI_MODEL_THINKING_EFFORT=" + $flags.effort)]
     else [] end)
    + ["kimi", "--session", $session]
    + (if $flags.permissionMode == "auto" then ["--auto"]
       elif $flags.permissionMode == "yolo"
         or $flags.yolo == true
         or $flags.dangerouslySkipPermissions == true then ["--yolo"]
       else [] end)
    + (if $flags.plan == true then ["--plan"] else [] end)
    + (if (($flags.model // "") | type == "string" and length > 0)
       then ["--model", $flags.model] else [] end)
    + extra_args
  ) as $command
  | {$command}
'

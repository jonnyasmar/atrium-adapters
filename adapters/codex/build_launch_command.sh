#!/usr/bin/env bash
set -euo pipefail

FLAGS="${1:-"{}"}"
RESUME=false
[ "$#" -lt 2 ] || RESUME=true

# One JSON pass preserves literal argv; the caller owns shell quoting.
exec jq -cn --argjson flags "$FLAGS" --argjson resume "$RESUME" --arg session "${2:-}" '
  $flags |
  {command: (
    ["codex"]
    + (if (.dangerouslySkipPermissions // .dangerous_skip_permissions // false)
       then ["--dangerously-bypass-approvals-and-sandbox"] else [] end)
    + (if (.model // "") != "" then ["-m", .model] else [] end)
    + (if (.effort // "") != ""
       then ["-c", "model_reasoning_effort=" + (.effort | tojson)] else [] end)
    + (if (.fast // false)
       then ["--enable", "fast_mode", "-c", "service_tier=\"fast\""] else [] end)
    + (if has("extraArgv") then
         .extraArgv | if type == "array" and all(.[]; type == "string")
         then . else error("extraArgv must be an array of strings") end
       else (.extraArgs // "" | [scan("[^ \t\r\n]+")]) end)
    + (if $resume then ["resume", $session] else [] end)
  )}
'

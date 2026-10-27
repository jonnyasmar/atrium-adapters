#!/usr/bin/env bash
set -euo pipefail
FLAGS="${1:-"{}"}"
RESUME=false
[ "$#" -lt 2 ] || RESUME=true
exec jq -cn --argjson flags "$FLAGS" --argjson resume "$RESUME" --arg session "${2:-}" '
  $flags | {command: (
    ["copilot"]
    + (if (.dangerouslySkipPermissions // false) then ["--allow-all"] else [] end)
    + (if (.model // "") != "" then ["--model", .model] else [] end)
    + (if (.effort // "") != "" then ["--reasoning-effort", .effort] else [] end)
    + (if has("extraArgv") then
         .extraArgv | if type == "array" and all(.[]; type == "string")
         then . else error("extraArgv must be an array of strings") end
       else (.extraArgs // "" | [scan("[^ \t\r\n]+")]) end)
    + (if $resume then ["--resume", $session] else [] end)
  )}
'

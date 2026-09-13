#!/usr/bin/env bash
set -euo pipefail

FLAGS="${1:-"{}"}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Windows: atrium types this argv into the pane shell, which is PowerShell by
# default. Two pieces of the Unix argv cannot survive there: the
# "env VAR=v" prefix (env is not a PowerShell command) and trust-workspace.sh
# as argv[0] (PowerShell cannot exec a .sh, and a bare `bash` word resolves to
# the WSL launcher in System32 rather than Git Bash).
# Both are gated off below via $isWin so the Unix filter is untouched.
# RECORDED DIVERGENCE on Windows:
#   - trust: true does not pre-accept the workspace, so kimi shows its trust
#     prompt (which defaults to Exit) instead of starting unattended;
#   - effort is delivered only through KIMI_MODEL_THINKING_EFFORT and kimi has
#     no equivalent flag, so a selected effort is not applied.
# Both default to off/empty in launcher_options.json, so the DEFAULT launch is
# unaffected and byte-identical to Unix.
IS_WINDOWS=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

jq -cn --argjson isWin "$IS_WINDOWS" --argjson flags "$FLAGS" --arg trustSh "${ADAPTER_DIR}/trust-workspace.sh" '
  def extra_args:
    ($flags.extraArgs // "")
    | if type != "string" then "" else . end
    | gsub("^\\s+|\\s+$"; "")
    | if length == 0 then [] else split(" ") | map(select(length > 0)) end;
  (
    # kimi has no --trust flag and its prompt defaults to "Don'"'"'t trust — Exit
    # Kimi Code", so an unattended launch quits. The wrapper writes the trust
    # record for $PWD, then execs the rest.
    (if ($isWin | not) and $flags.trust == true then [$trustSh] else [] end)
    + (if ($isWin | not) and (($flags.effort // "") | type == "string" and length > 0)
     then ["env", ("KIMI_MODEL_THINKING_EFFORT=" + $flags.effort)]
     else [] end)
    + ["kimi"]
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

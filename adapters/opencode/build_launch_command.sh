#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch OpenCode.
# OpenCode treats the first positional arg as the project path, defaulting
# to cwd when omitted. Atrium always launches from the pane's cwd, so we
# don't pass it explicitly — opencode infers it from process.cwd().
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode", ...flags]}
#
# An effort (opencode "variant") swaps argv's `opencode` for
# ATRIUM_OPENCODE_VARIANT=<v> opencode-with-variant.sh — see that wrapper for
# why. It needs an explicit model: opencode applies an agent variant only
# while the agent's model matches the prompt's.
#
# The jq filter is one parenthesised expression: atrium's script PATH prefers
# /usr/bin/jq (Apple 1.7.1), which rejects ungrouped multi-line `+` chains.
# Keep the defs in sync with build_resume_command.sh.

FLAGS="${1:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/opencode-with-variant.sh"
[ -f "$WRAPPER" ] || WRAPPER=""

if ! command -v jq &>/dev/null; then
  echo '{"command": ["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode"]}'
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq -e 'type == "object"' >/dev/null 2>&1; then
  FLAGS='{}'
fi

jq -nc --argjson flags "$FLAGS" --arg wrapper "$WRAPPER" '
  def str($k): ($flags[$k] // "") | if type == "string" then . else "" end;
  def variant:
    str("effort") as $e
    | if ($e | test("^[A-Za-z0-9_-]+$")) and str("model") != ""
         and $wrapper != "" and ($wrapper | test("\\s") | not)
      then $e else "" end;
  def opencode_head:
    variant as $v
    | if $v != "" then [("ATRIUM_OPENCODE_VARIANT=" + $v), $wrapper] else ["opencode"] end;
  def model_agent_args:
    (if str("model") != "" then ["--model", str("model")] else [] end)
    + (if str("agent") != "" then ["--agent", str("agent")] else [] end);
  def extra_args: str("extraArgs") | split(" ") | map(select(length > 0));
  (
    ["env", "OPENCODE_DISABLE_AUTOUPDATE=1"]
    + opencode_head
    # Auto mode: auto-approve permission requests not explicitly denied
    # (explicit "deny" rules still enforced). permissionMode=auto covers
    # atrium chat/launcher flows that request the mode by name.
    + (if ($flags.autoApprove | tostring) == "true" or $flags.permissionMode == "auto"
       then ["--auto"] else [] end)
    + model_agent_args
    + extra_args
  ) as $command
  | {$command}
'
exit 0

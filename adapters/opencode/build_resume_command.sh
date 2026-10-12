#!/usr/bin/env bash
set -euo pipefail

# build_resume_command.sh — Build the command to resume an OpenCode session.
# OpenCode resume format: opencode --session <session_id>
# Takes $1 = session ID, $2 = JSON flags
# Output: {"command": ["env", "OPENCODE_DISABLE_AUTOUPDATE=1", "opencode", "--session", "session-id", ...flags]}
#
# `env`, not a bare `VAR=1` prefix: chat→terminal handoff POSIX-quotes every
# argv word, and a quoted assignment is a command name to the shell.
# An effort swaps `opencode` for the variant wrapper exactly as in
# build_launch_command.sh (keep the defs in sync).

SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
FLAGS="${2:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/opencode-with-variant.sh"
[ -f "$WRAPPER" ] || WRAPPER=""

if ! command -v jq &>/dev/null; then
  ESCAPED_SESSION_ID="$(printf '%s' "$SESSION_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  echo "{\"command\": [\"env\", \"OPENCODE_DISABLE_AUTOUPDATE=1\", \"opencode\", \"--session\", \"${ESCAPED_SESSION_ID}\"]}"
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq -e 'type == "object"' >/dev/null 2>&1; then
  FLAGS='{}'
fi

jq -nc --argjson flags "$FLAGS" --arg wrapper "$WRAPPER" --arg session "$SESSION_ID" '
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
    + ["--session", $session]
    + model_agent_args
    + extra_args
  ) as $command
  | {$command}
'
exit 0

#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the antigravity adapter.
# Verifies that ~/.gemini/config/hooks.json contains an "atrium" hook
# block with all five expected events in their correct (asymmetric)
# shapes: PreToolUse/PostToolUse wrapped with {matcher, hooks: [...]};
# PreInvocation/PostInvocation/Stop as flat handler lists.
#
# Args: $1 = adapter name (unused here; provided for future generic assertions)

HOOKS_FILE="${HOME}/.gemini/config/hooks.json"

if [[ ! -f "$HOOKS_FILE" ]]; then
  echo "install.assert: $HOOKS_FILE does not exist" >&2
  exit 1
fi

# Expected: .atrium block exists with the four wired events. PostInvocation
# is intentionally absent (per-invocation, would bounce the activity card).
missing="$(jq -r '
  .atrium // {} as $a
  | [
      (if ($a.PreToolUse | type) == "array" and (($a.PreToolUse[0].hooks // []) | length) > 0 then empty else "PreToolUse" end),
      (if ($a.PostToolUse | type) == "array" and (($a.PostToolUse[0].hooks // []) | length) > 0 then empty else "PostToolUse" end),
      (if ($a.PreInvocation | type) == "array" and (($a.PreInvocation[0].command // "") | length) > 0 then empty else "PreInvocation (flat)" end),
      (if ($a.Stop | type) == "array" and (($a.Stop[0].command // "") | length) > 0 then empty else "Stop (flat)" end)
    ]
  | join(", ")
' "$HOOKS_FILE")"

if [[ -n "$missing" ]]; then
  echo "install.assert: missing/malformed events: $missing" >&2
  jq '.atrium | keys' "$HOOKS_FILE" >&2
  exit 1
fi

# Every command must carry the atrium marker so uninstall can find ours.
unmarked="$(jq -r '
  .atrium // {}
  | [.PreToolUse[0].hooks[0].command, .PostToolUse[0].hooks[0].command,
     .PreInvocation[0].command, .Stop[0].command]
  | map(select(test("ATRIUM_HOOK_MARKER=atrium-runtime-hook") | not))
  | length
' "$HOOKS_FILE")"

if [[ "$unmarked" != "0" ]]; then
  echo "install.assert: $unmarked hook command(s) missing atrium marker" >&2
  exit 1
fi

exit 0

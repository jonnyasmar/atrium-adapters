#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the grok adapter.
# Verifies that ~/.grok/hooks/atrium-grok.json contains a hooks block
# mapping every wired event to a marked atrium command, with no
# matcher field on any entry (grok's v0 hook validator rejects
# lifecycle hooks that specify a matcher).

HOOKS_FILE="${HOME}/.grok/hooks/atrium-grok.json"

if [[ ! -f "$HOOKS_FILE" ]]; then
  echo "install.assert: $HOOKS_FILE missing" >&2
  exit 1
fi

# Every wired event is present and contains at least one entry with
# at least one hook command.
missing="$(jq -r '
  .hooks // {} as $h
  | [
      (if ($h.SessionStart         | type) == "array" and (($h.SessionStart[0].hooks         // []) | length) > 0 then empty else "SessionStart" end),
      (if ($h.SessionEnd           | type) == "array" and (($h.SessionEnd[0].hooks           // []) | length) > 0 then empty else "SessionEnd" end),
      (if ($h.PreToolUse           | type) == "array" and (($h.PreToolUse[0].hooks           // []) | length) > 0 then empty else "PreToolUse" end),
      (if ($h.PostToolUse          | type) == "array" and (($h.PostToolUse[0].hooks          // []) | length) > 0 then empty else "PostToolUse" end),
      (if ($h.PostToolUseFailure   | type) == "array" and (($h.PostToolUseFailure[0].hooks   // []) | length) > 0 then empty else "PostToolUseFailure" end),
      (if ($h.Stop                 | type) == "array" and (($h.Stop[0].hooks                 // []) | length) > 0 then empty else "Stop" end),
      (if ($h.StopFailure          | type) == "array" and (($h.StopFailure[0].hooks          // []) | length) > 0 then empty else "StopFailure" end),
      (if ($h.UserPromptSubmit     | type) == "array" and (($h.UserPromptSubmit[0].hooks     // []) | length) > 0 then empty else "UserPromptSubmit" end),
      (if ($h.SubagentStart        | type) == "array" and (($h.SubagentStart[0].hooks        // []) | length) > 0 then empty else "SubagentStart" end),
      (if ($h.SubagentStop         | type) == "array" and (($h.SubagentStop[0].hooks         // []) | length) > 0 then empty else "SubagentStop" end)
    ]
  | join(", ")
' "$HOOKS_FILE")"

if [[ -n "$missing" ]]; then
  echo "install.assert: missing/malformed events: $missing" >&2
  jq '.hooks | keys' "$HOOKS_FILE" >&2
  exit 1
fi

# No entry on any event has a `matcher` field — grok v0's hook
# discovery drops entries on SessionStart / UserPromptSubmit / Stop /
# Notification / SessionEnd / SubagentStop that specify a matcher.
# We omit the field everywhere (Pre/PostToolUse accept matchers but
# we follow the reference plugin shape and omit there too).
with_matcher="$(jq -r '
  [.hooks | to_entries[] | .value[] | select(has("matcher"))] | length
' "$HOOKS_FILE")"

if [[ "$with_matcher" != "0" ]]; then
  echo "install.assert: $with_matcher entry/entries still carry a matcher (grok v0 rejects matchers on lifecycle hooks)" >&2
  jq '.hooks | to_entries[] | .value[] | select(has("matcher"))' "$HOOKS_FILE" >&2
  exit 1
fi

# Every primary atrium command must carry the atrium marker so
# uninstall/status detection can identify ours unambiguously.
unmarked="$(jq -r '
  [.hooks.PreToolUse[0].hooks[0].command,
   .hooks.PostToolUse[0].hooks[0].command,
   .hooks.PostToolUseFailure[0].hooks[0].command,
   .hooks.Stop[0].hooks[0].command,
   .hooks.StopFailure[0].hooks[0].command,
   .hooks.UserPromptSubmit[0].hooks[0].command,
   .hooks.SessionEnd[0].hooks[0].command,
   .hooks.SubagentStart[0].hooks[0].command]
  | map(select(test("ATRIUM_HOOK_MARKER=atrium-runtime-hook") | not))
  | length
' "$HOOKS_FILE")"

if [[ "$unmarked" != "0" ]]; then
  echo "install.assert: $unmarked hook command(s) missing atrium marker" >&2
  exit 1
fi

# PostToolUseFailure must re-emit as atrium post-tool-use (no dedicated
# atrium event); the normalize step still receives post-tool-use-failure.
# The normalizer path is double-quoted in the installed command
# (`".../normalize-hook-payload.sh" post-tool-use-failure`), so match
# the event tokens without requiring a bare `sh ` boundary.
failure_cmd="$(jq -r '.hooks.PostToolUseFailure[0].hooks[0].command // empty' "$HOOKS_FILE")"
if ! printf '%s' "$failure_cmd" | grep -qE 'normalize-hook-payload\.sh"?[[:space:]]+post-tool-use-failure'; then
  echo "install.assert: PostToolUseFailure must normalize as post-tool-use-failure" >&2
  exit 1
fi
if ! printf '%s' "$failure_cmd" | grep -qE 'hook emit post-tool-use([[:space:]]|$)'; then
  echo "install.assert: PostToolUseFailure must emit atrium post-tool-use" >&2
  exit 1
fi

exit 0

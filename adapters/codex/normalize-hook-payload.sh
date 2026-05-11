#!/usr/bin/env bash
# normalize-hook-payload.sh — Codex adapter.
#
# Reads Codex's native hook payload from stdin, enriches it with the
# `_atrium` envelope (see ../../HOOK_ENVELOPE.md), and writes the
# augmented payload to stdout.
#
# Codex's main write tool is `apply_patch`. Unlike Claude/Gemini, the
# file path is NOT a discrete field — Codex embeds the raw patch text
# in `tool_input.command` (or `tool_input.input`), with one
# `*** (Update|Add|Delete|Move) File:` header line per affected file.
# We parse those headers to recover the file list. Multi-file patches
# yield multiple entries; move operations record the destination.
#
# Shell commands (`shell`, `run_shell_command`), reads (`view_image`),
# planner ops (`update_plan`) pass through unchanged.

set -euo pipefail

input="$(cat)"

enriched="$(
  printf '%s' "$input" | jq -c '
    def parse_patch_targets(text):
      (text // "")
      | split("\n")
      | map(
          if test("^[[:space:]]*\\*\\*\\* Update File:") then
            (capture("^[[:space:]]*\\*\\*\\* Update File:[[:space:]]*(?<p>.+?)[[:space:]]*$") | .p)
          elif test("^[[:space:]]*\\*\\*\\* Add File:") then
            (capture("^[[:space:]]*\\*\\*\\* Add File:[[:space:]]*(?<p>.+?)[[:space:]]*$") | .p)
          elif test("^[[:space:]]*\\*\\*\\* Delete File:") then
            (capture("^[[:space:]]*\\*\\*\\* Delete File:[[:space:]]*(?<p>.+?)[[:space:]]*$") | .p)
          elif test("^[[:space:]]*\\*\\*\\* Move File:") then
            (capture("^[[:space:]]*\\*\\*\\* Move File:[[:space:]]*(?<rest>.+?)[[:space:]]*$").rest
             | if test(" -> ") then (split(" -> ") | last) else . end)
          else
            empty
          end
        )
      | map(select(length > 0));

    . as $p
    | (.tool_name // "") as $tool
    | (.tool_input // {}) as $ti
    | if $tool == "apply_patch" then
        (parse_patch_targets($ti.command // $ti.input // "")) as $files
        | if ($files | length > 0) then
            $p + {
              _atrium: {
                writeKind: "patch",
                filePaths: $files,
                lineStart: null,
                lineEnd: null
              }
            }
          else
            $p
          end
      else
        $p
      end
  ' 2>/dev/null || true
)"

if [ -n "$enriched" ]; then
  printf '%s' "$enriched"
else
  printf '%s' "$input"
fi

#!/usr/bin/env bash
# normalize-hook-payload.sh — Gemini adapter.
#
# Reads Gemini's native hook payload from stdin, enriches it with
# the `_atrium` envelope (see ../../HOOK_ENVELOPE.md), and writes
# the augmented payload to stdout.
#
# Gemini's write tools:
#   - `replace`    — hunk-level edit (`file_path` + `old_string` + `new_string`)
#   - `write_file` — full-file write (`file_path` + `content`)
#
# Read tools (`read_file`, `list_directory`, `glob`) and shell
# (`run_shell_command`) carry no filesystem write — they pass through
# unchanged.

set -euo pipefail

input="$(cat)"

enriched="$(
  printf '%s' "$input" | jq -c '
    . as $p
    | (.tool_name // "") as $tool
    | (.tool_input // {}) as $ti
    | (
        if $tool == "replace" then
          {
            writeKind: "edit",
            filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif $tool == "write_file" then
          {
            writeKind: "write",
            filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        else
          null
        end
      ) as $atrium
    | if ($atrium != null) and (($atrium.filePaths // []) | length > 0) then
        $p + {_atrium: $atrium}
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

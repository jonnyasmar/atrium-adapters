#!/usr/bin/env bash
# normalize-hook-payload.sh — Cursor Agent adapter.
#
# Reads Cursor's native hook payload from stdin, enriches it with
# the `_atrium` envelope (see ../../HOOK_ENVELOPE.md), and writes the
# augmented payload to stdout.
#
# ⚠️  Cursor's PostToolUse payload shape is observed-by-inference. The
# tool-name set below is an educated guess based on Cursor's agent
# design (similar surface to Claude Code). If the pill stays empty
# when you test in a Cursor session, capture an actual payload (e.g.
# by re-adding the `eprintln!` diagnostic to
# `session_telemetry_subscriber.rs::handle_event` in atrium, or by
# logging stdin here to stderr) and add the missing tool name to the
# jq filter below.
#
# Expected branches (covers both PascalCase and snake_case styles):
#   - Edit / edit_file       → writeKind: "edit"
#   - MultiEdit / multi_edit → writeKind: "multi-edit"
#   - Write / write_file / create_file → writeKind: "write"
#   - apply_patch / apply_diff → writeKind: "patch" (full path scan)

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
    | (
        if ($tool == "Edit") or ($tool == "edit_file") or ($tool == "search_replace") then
          {
            writeKind: "edit",
            filePaths: ([$ti.file_path, $ti.path, $ti.target_file]
                        | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif ($tool == "MultiEdit") or ($tool == "multi_edit") then
          {
            writeKind: "multi-edit",
            filePaths: ([$ti.file_path, $ti.path, $ti.target_file]
                        | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif ($tool == "Write") or ($tool == "write_file") or ($tool == "create_file") then
          {
            writeKind: "write",
            filePaths: ([$ti.file_path, $ti.path, $ti.target_file]
                        | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif ($tool == "apply_patch") or ($tool == "apply_diff") then
          (parse_patch_targets($ti.command // $ti.input // $ti.diff // $ti.patch // "")) as $files
          | if ($files | length > 0) then
              { writeKind: "patch", filePaths: $files, lineStart: null, lineEnd: null }
            else
              null
            end
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

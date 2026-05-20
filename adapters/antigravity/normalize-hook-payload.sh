#!/usr/bin/env bash
# normalize-hook-payload.sh — Antigravity (agy) adapter.
#
# Wired only into the PreToolUse hook command. agy's PostToolUse stdin
# does NOT carry tool info (only stepIdx + optional error), so atrium
# relies on the pre-tool-use envelope for file-touch attribution. Per
# atrium's HOOK_ENVELOPE.md contract (../../HOOK_ENVELOPE.md), the
# `_atrium` key carries the canonical write summary that downstream
# consumers read.
#
# agy PreToolUse stdin shape (per Antigravity hooks docs):
#   { toolCall: { name: "write_to_file"|..., args: {...} },
#     stepIdx, conversationId, workspacePaths, ... }
#
# agy's documented write-tool surface:
#   - `write_to_file`             — full-file write (args.TargetFile)
#   - `replace_file_content`      — single-block edit (args.TargetFile)
#   - `multi_replace_file_content`— multiple non-contiguous edits (args.TargetFile)
#
# Read tools (`view_file`, `list_dir`, `find_by_name`, `grep_search`,
# `read_url_content`), shell (`run_command`, `manage_task`, `schedule`),
# permission/collab tools, and media tools pass through unchanged.

set -euo pipefail

input="$(cat)"

enriched="$(
  printf '%s' "$input" | jq -c '
    . as $p
    | (.toolCall.name // "") as $tool
    | (.toolCall.args // {}) as $a
    | (
        if $tool == "write_to_file" then
          {
            writeKind: "write",
            filePaths: ([$a.TargetFile] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif $tool == "replace_file_content" then
          {
            writeKind: "edit",
            filePaths: ([$a.TargetFile] | map(select(type == "string" and length > 0))),
            lineStart: ($a.StartLine // null),
            lineEnd: ($a.EndLine // null)
          }
        elif $tool == "multi_replace_file_content" then
          {
            writeKind: "multi-edit",
            filePaths: ([$a.TargetFile] | map(select(type == "string" and length > 0))),
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

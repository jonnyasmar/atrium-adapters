#!/usr/bin/env bash
# normalize-hook-payload.sh — Claude Code adapter.
#
# Reads Claude's native hook payload from stdin, enriches it with the
# `_atrium` envelope (see ../../HOOK_ENVELOPE.md), and writes the
# augmented payload to stdout.
#
# Claude PostToolUse payload shape (the only event we enrich):
#   { tool_name: "Edit"|"MultiEdit"|"Write"|...,
#     tool_input: { file_path: "...", ... } }
#
# Non-write events pass through unchanged — atrium only reads
# `_atrium` on PostToolUse.
#
# Fail-safe: if jq fails for any reason, the original payload is
# written verbatim so atrium's legacy fallback extraction still
# fires.

set -euo pipefail

input="$(cat)"

enriched="$(
  printf '%s' "$input" | jq -c '
    . as $p
    | (.tool_name // "") as $tool
    | (.tool_input // {}) as $ti
    | (
        if $tool == "Edit" then
          {
            writeKind: "edit",
            filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif $tool == "MultiEdit" then
          {
            writeKind: "multi-edit",
            filePaths: ([$ti.file_path] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif $tool == "Write" then
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

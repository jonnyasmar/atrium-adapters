#!/usr/bin/env bash
# normalize-hook-payload.sh — OpenCode adapter.
#
# Reads the post-tool-use payload emitted by the atrium plugin
# (`plugin/atrium.js`) from stdin, enriches it with the `_atrium` envelope
# (see ../../HOOK_ENVELOPE.md), and writes the augmented payload to stdout.
#
# The plugin packages opencode's `tool.execute.after` input as:
#   { tool: "edit"|"write"|"patch"|...,
#     args: { filePath: "...", patchText?: "..." } }
#
# OpenCode's documented write-tool surface:
#   - `edit`        — hunk-level edit (`filePath` + `oldString` + `newString`)
#   - `write`       — full-file write (`filePath` + `content`)
#   - `apply_patch` — multi-file patch (`patchText`, no `filePath`)
#
# Non-write events pass through unchanged.

set -euo pipefail

input="$(cat)"

enriched="$(
  printf '%s' "$input" | jq -c '
    . as $p
    | (.tool // "") as $tool
    | (.args // {}) as $a
    | (
        if $tool == "edit" then
          {
            writeKind: "edit",
            filePaths: ([$a.filePath] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif $tool == "write" then
          {
            writeKind: "write",
            filePaths: ([$a.filePath] | map(select(type == "string" and length > 0))),
            lineStart: null,
            lineEnd: null
          }
        elif $tool == "apply_patch" then
          # apply_patch carries no filePath in args — atrium core extracts
          # paths from the patch text itself. We still mark the writeKind
          # so the consumer knows the agent wrote to disk.
          {
            writeKind: "patch",
            filePaths: [],
            lineStart: null,
            lineEnd: null
          }
        else
          null
        end
      ) as $atrium
    | if $atrium != null then
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

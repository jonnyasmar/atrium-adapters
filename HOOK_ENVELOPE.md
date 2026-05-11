# Hook Payload Envelope (`_atrium`)

atrium consumes a **canonical** hook payload shape. Every adapter is responsible for normalising its native payload to this contract **before** piping to `atrium hook emit`. atrium core does **not** know about adapter-specific tool names or payload quirks — that knowledge lives entirely in each adapter's `normalize-hook-payload.sh`.

This document is the contract. New adapters implement it; existing adapters maintain it.

## Why an envelope

atrium needs to know, per `PostToolUse` event:

- **Did the agent write to the filesystem?** (yes/no)
- **Which file(s)?** (list of paths)
- **What kind of write?** (edit, multi-edit, full write, patch)
- **For hunk-level edits, what lines?** (optional anchor)

Different adapters ship wildly different tool names and payload shapes (Claude has `Edit`/`Write`, Codex puts the whole patch in `tool_input.command`, Gemini calls its edit tool `replace`, etc.). Without normalisation, atrium core would need a hardcoded switch for every adapter — and every new adapter would require a code change in the main repo. The envelope makes adapters truly pluggable.

## Contract

Each adapter MUST pipe `PostToolUse` payloads through a normalizer that adds an `_atrium` key. Other event types MAY pass through unchanged.

```jsonc
{
  // ... original adapter-native fields preserved unchanged ...
  "session_id": "abc-123",
  "tool_name": "apply_patch",
  "tool_input": { "command": "*** Begin Patch\n*** Update File: src/foo.ts\n..." },

  // ── atrium envelope (REQUIRED for write tools) ──
  "_atrium": {
    "writeKind": "patch",                            // see writeKind values below
    "filePaths": ["src/foo.ts", "src/bar.ts"],       // every file touched, in document order
    "lineStart": null,                               // optional, hunk-level edits only
    "lineEnd": null                                  // optional, hunk-level edits only
  }
}
```

### `writeKind` values

| Value         | Meaning                                                              |
| ------------- | -------------------------------------------------------------------- |
| `"edit"`      | Hunk-level edit (find-and-replace within an existing file).          |
| `"multi-edit"`| Multiple edits batched into one tool call against one file.          |
| `"write"`     | Full-file write (create or overwrite).                               |
| `"patch"`     | Unified-diff-style patch, potentially across multiple files.         |

For non-write events (reads, shell commands, planner tools), **omit the `_atrium` key entirely** — do not set it to `null` or an empty object. Absence is the signal to atrium that this event has no filesystem effect to record.

### `filePaths`

- Strings. Paths may be repo-relative or absolute — atrium normalizes downstream.
- For move/rename operations, record the **destination** path.
- Multi-file patches MUST emit every touched file.

### `lineStart` / `lineEnd`

Optional. 1-based, inclusive. Populate for `"edit"` when the adapter knows the hunk anchor (e.g. Claude's `Edit` carries `old_string` which can be located in the file). Leave `null` otherwise — atrium handles missing anchors gracefully.

## Implementation pattern

Each adapter ships a `normalize-hook-payload.sh` next to its `hooks.sh`:

```bash
#!/usr/bin/env bash
# Read native payload from stdin, write enriched payload to stdout.
# MUST always pass through the original payload if normalisation fails —
# atrium has legacy fallback extraction for Claude-shaped payloads.

set -euo pipefail
input="$(cat)"
enriched="$(printf '%s' "$input" | jq -c '<adapter-specific transform>' 2>/dev/null || true)"
if [ -n "$enriched" ]; then printf '%s' "$enriched"; else printf '%s' "$input"; fi
```

And `hooks.sh::build_hook_command` inserts the normalizer in the pipe for `post-tool-use` events:

```bash
build_hook_command() {
  local event="$1"
  local adapter_dir
  adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local normalizer=""
  if [ "$event" = "post-tool-use" ]; then
    normalizer="\"${adapter_dir}/normalize-hook-payload.sh\" | "
  fi
  printf '%s; %s"${ATRIUM_CLI_PATH:-atrium}" hook emit %s --adapter <name> --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$normalizer" "$event"
}
```

`$adapter_dir` is resolved at install time, so the path is baked into the hook command stored in the adapter's config file.

## Performance

Adapter scripts must complete in under 50ms (CLAUDE.md). The normalizer is one `jq` invocation per `PostToolUse` event — well under budget. Heavy parsing (patch markers, etc.) is done in jq, not by spawning subprocesses.

## Reference implementations

- `adapters/claude-code/normalize-hook-payload.sh` — simplest case (direct field copy)
- `adapters/gemini/normalize-hook-payload.sh` — tool-name renames
- `adapters/codex/normalize-hook-payload.sh` — patch-text parsing

New adapters can crib whichever is closest to their payload shape.

## Versioning

The envelope is **additive**: future versions may add fields under `_atrium`. Adapters MUST NOT emit fields they don't intend to set. atrium MUST ignore unknown fields.

There is no `version` field today. If a breaking change is needed, an `envelopeVersion` field will be introduced; adapters that don't emit it will be treated as v1.

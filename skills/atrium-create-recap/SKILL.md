---
name: atrium-create-recap
description: "Synthesize a time-bounded recap of what happened in a workspace over a window (default the last 7 days) from the timeline + open tasks, and persist it as a typed `recap` timeline entry. Use when the user wants a 'what happened this week / since <date>' summary or invokes /atrium-create-recap — it reads the timeline for the window and writes one recap narrative tagged with the exact time range it covers."
version: "0.1.0"
---

# atrium-create-recap — synthesize a time-bounded recap

Turn the workspace **timeline** over a specific window (default: the last 7 days) plus its **open tasks** into a **recap** — a narrative of what happened in that window. It's persisted as a typed `recap` timeline entry, tagged with the exact range it covers. atrium runs no LLM — *you* read the source, write the narrative, and persist it via the CLI.

Confirm any flag with `"$ATRIUM_CLI_PATH" <cmd> --help` before guessing — the CLI is the source of truth.

## Inputs

| Flag | Meaning | Default |
|---|---|---|
| `--since <RFC3339>` | Start of the recap window (a concrete instant) | 7 days back |
| `--until <RFC3339>` | End of the recap window (a concrete instant) | now |
| `--scope <S>` | Canonical scope string to read + write at | the workspace scope `workspace:<workspaceId>` from `context` |

A user may ask for the window in relative terms ("the last 7 days", "since last Monday") — **resolve it to concrete RFC3339 instants before reading** (`--since`/`--until` take an instant only, not relative `7d`). The same resolved start/end feed both the read (step 2) and `RecapMeta.timeRange` (step 4).

## Synthesis flow

### 1. Resolve scope

```bash
"$ATRIUM_CLI_PATH" context --json
```

Read **`workspaceId`** — needed for both `--scope` and the **required** `--workspace` on append. Use a caller-passed `--scope` verbatim; otherwise default to `workspace:<workspaceId>`. Deeper scopes (`room:`/`pane:`/`worktree:<ws>/…`) are opt-in via `--scope`.

### 2. Read the source data over the window

Resolve the window to two concrete RFC3339 instants first — one start, one end. These same values also drive `RecapMeta.timeRange` in step 4:

```bash
START=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)   # macOS  (Linux: date -u -d '7 days ago' …)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# If the user passed explicit --since / --until, resolve those to instants instead.
```

```bash
"$ATRIUM_CLI_PATH" timeline list --json --scope "workspace:<workspaceId>" --since "$START" --until "$END"
"$ATRIUM_CLI_PATH" task list --json
```

**Collect the `id` of every timeline entry you draw from** — they become `synthesizedFrom.eventIds`. Keep `START` / `END` for `RecapMeta.timeRange`.

### 3. Synthesize — summary, sentinel, then narrative

Structure the text as **summary → sentinel → detail**, in exactly this order:

```markdown
<1–3 sentence, high-signal summary of the window>

<!-- more -->

<full time-bounded narrative>
```

The `<!-- more -->` line is an HTML comment (invisible when rendered) where the timeline card splits summary from detail. Write a time-bounded narrative: the work that landed, threads that moved, decisions made, and what's still open at the window's end. State the window plainly (e.g. "the last 7 days" or the explicit dates).

This one text is consumed in **two cuts**: the backing **note** (step 4) holds the full prose; the timeline **`--body`** (step 5) holds **only the summary** (the text above the sentinel). The card shows the summary; clicking it opens the note.

### 4. Create the backing note (full prose)

Markdown notes have **no `--body` flag** (that's canvas/html only) — create from `--title`, then write the body separately. Capture `noteId` from the `--json` (`{"noteId":"<uuid>",…}`):

```bash
NOTE_ID=$("$ATRIUM_CLI_PATH" note new --title "<one-line recap summary>" \
  --type markdown --source agent --workspace "<workspaceId>" --json | jq -r '.noteId')

printf '%s' "<the full recap prose>" | "$ATRIUM_CLI_PATH" note write "$NOTE_ID"
```

Note **title** = the one-line summary (same string as the timeline `--title`); note **body** = the full prose (summary + sentinel + detail). `note write` takes `--content`, `--from-file`, or piped stdin — **don't** pass it `--source` (rejected; the note already carries `source: agent` from `note new`).

### 5. Persist — one `timeline append`

```bash
"$ATRIUM_CLI_PATH" timeline append \
  --workspace "<workspaceId>" --kind recap --scope "workspace:<workspaceId>" \
  --title "<one-line recap summary>" \
  --body "<the SUMMARY only — text above the <!-- more --> sentinel>" \
  --metadata-json "{\"timeRange\":[\"$START\",\"$END\"],\"synthesizedFrom\":{\"eventIds\":[\"<id1>\",\"<id2>\"]},\"tags\":[\"topic:weekly\"],\"noteId\":\"$NOTE_ID\"}" \
  --json
```

`--workspace` is **required** (no implicit current workspace). `--kind recap` matches the timeline kind verbatim. `--metadata-json` is passed through **verbatim** — the JSON you write **is** the wire shape (the bare `RecapMeta` below; atrium doesn't reshape it). Keep `--body` to the summary only — the full prose lives solely in the note (duplicating it bloats storage, goes stale on note edits, and double-indexes FTS).

**`RecapMeta`:**

```json
{
  "timeRange": ["<startIso>", "<endIso>"],
  "synthesizedFrom": { "eventIds": ["<timeline id>", "..."] },
  "tags": ["topic:weekly"],
  "noteId": "<note id from step 4>"
}
```

- `timeRange` is **camelCase**, a two-element `[start, end]` array of ISO-8601 instants — the window from step 2. It lives at the **top level**, NOT inside `synthesizedFrom`.
- `synthesizedFrom` carries **only** `eventIds` (+ optional `"label"`) — nothing else.
- `tags` — `<ns>:<value>` strings embedded here so `timeline list --tag` finds the row. Syntax `^[a-z][a-z0-9-]*:[a-zA-Z0-9_-]+$`; an invalid tag rejects the whole append. Omit or `[]` if none.
- `noteId` — the step-4 note id (lets the card open the note). This skill always creates a note, so always set it.

### 6. Report

Read `id` from the append `--json` and report it — e.g. "Recap of the last 7 days saved as timeline entry `<id>`." The append is synchronous and immediately listable.

## Scope boundary

Ends after reporting the id — it only reads the window, synthesizes the recap, and persists the `recap` entry. No delivery, dispatch, or UI wiring.

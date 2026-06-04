---
name: atrium-create-brief
description: "Synthesize a project brief from the workspace timeline + open tasks and persist it as a typed `brief` timeline entry, pinned in the sidebar. Use when the user returns to a workspace cold and asks 'what is this / where did I leave off', wants a fresh orientation, or invokes /atrium-create-brief — it reads the recent timeline and open work and writes a single cold-resume brief the user can pick back up from."
version: "0.1.0"
---

# atrium-create-brief — synthesize a cold-resume project brief

Turn the workspace **timeline** (prompts, commits, task changes, agent messages, prior syntheses) plus its **open tasks** into a **project brief** — a cold-resume orientation a returning user or agent can pick the project back up from. It's persisted as a typed `brief` timeline entry, pinned in the sidebar. atrium runs no LLM — *you* read the source, write the narrative, and persist it via the CLI.

Confirm any flag with `"$ATRIUM_CLI_PATH" <cmd> --help` before guessing — the CLI is the source of truth.

## Inputs

| Flag | Meaning | Default |
|---|---|---|
| `--scope <S>` | Canonical scope string to read + write at | the workspace scope `workspace:<workspaceId>` from `context` |
| `--since <RFC3339>` | How far back to read (a concrete instant — resolve relative requests first) | 30 days back (a brief takes a wide view) |

## Synthesis flow

### 1. Resolve scope

```bash
"$ATRIUM_CLI_PATH" context --json
```

Read **`workspaceId`** — needed for both `--scope` and the **required** `--workspace` on append. Use a caller-passed `--scope` verbatim; otherwise default to `workspace:<workspaceId>`. Deeper scopes (`room:`/`pane:`/`worktree:<ws>/…`, workspace UUID always first) are opt-in via `--scope`.

### 2. Read the source data

Resolve the read window to a concrete RFC3339 instant first (`--since` takes an instant, not a relative duration like `7d`):

```bash
SINCE=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)   # macOS  (Linux: date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
```

```bash
"$ATRIUM_CLI_PATH" timeline list --json --scope "workspace:<workspaceId>" --since "$SINCE"
"$ATRIUM_CLI_PATH" task list --json
```

A brief uses a wide window because it orients the reader to the whole project, not a slice. **Collect the `id` of every timeline entry you draw from** — they become `synthesizedFrom.eventIds` (the attribution link back to the originals).

### 3. Synthesize — summary, sentinel, then orientation

Structure the text as **summary → sentinel → detail**, in exactly this order:

```markdown
<1–3 sentence, high-signal orientation summary>

<!-- more -->

<full cold-resume orientation narrative>
```

The `<!-- more -->` line is an HTML comment (invisible when rendered) where the timeline card splits summary from detail. Write the orientation as if the reader has zero context: **what this workspace is** (project, purpose, stack), **where it left off** (last commits / agent work / syntheses), and **what's open** (open tasks and in-flight threads). Keep it tight and skimmable — it lands in the pinned-latest sidebar slot.

This one text is consumed in **two cuts**: the backing **note** (step 4) holds the full prose; the timeline **`--body`** (step 5) holds **only the summary** (the text above the sentinel). The card shows the summary; clicking it opens the note.

### 4. Create the backing note (full prose)

Markdown notes have **no `--body` flag** (that's canvas/html only) — create from `--title`, then write the body separately. Capture `noteId` from the `--json` (`{"noteId":"<uuid>",…}`):

```bash
NOTE_ID=$("$ATRIUM_CLI_PATH" note new --title "<one-line orientation>" \
  --type markdown --source agent --workspace "<workspaceId>" --json | jq -r '.noteId')

printf '%s' "<the full brief prose>" | "$ATRIUM_CLI_PATH" note write "$NOTE_ID"
```

Note **title** = the one-line orientation (same string as the timeline `--title`); note **body** = the full prose (summary + sentinel + detail). `note write` takes `--content`, `--from-file`, or piped stdin — **don't** pass it `--source` (rejected; the note already carries `source: agent` from `note new`).

### 5. Persist — one `timeline append`

```bash
"$ATRIUM_CLI_PATH" timeline append \
  --workspace "<workspaceId>" --kind brief --scope "workspace:<workspaceId>" \
  --title "<one-line orientation>" \
  --body "<the SUMMARY only — text above the <!-- more --> sentinel>" \
  --metadata-json "{\"synthesizedFrom\":{\"eventIds\":[\"<id1>\",\"<id2>\"]},\"tags\":[\"scope:project\"],\"noteId\":\"$NOTE_ID\"}" \
  --json
```

`--workspace` is **required** (no implicit current workspace). `--kind brief` matches the timeline kind verbatim. `--metadata-json` is passed through **verbatim** — the JSON you write **is** the wire shape (the bare `BriefMeta` below; atrium doesn't reshape it). Keep `--body` to the summary only — the full prose lives solely in the note (duplicating it bloats storage, goes stale on note edits, and double-indexes FTS).

**`BriefMeta`:**

```json
{
  "synthesizedFrom": { "eventIds": ["<timeline id>", "..."] },
  "tags": ["scope:project", "topic:onboarding"],
  "noteId": "<note id from step 4>"
}
```

- `synthesizedFrom` carries **only** `eventIds` (+ optional `"label"`) — nothing else (no `timeRange`, `scope`, or `taskIds`; extra keys are dropped on read).
- `tags` — `<ns>:<value>` strings embedded here so `timeline list --tag` finds the row. Syntax `^[a-z][a-z0-9-]*:[a-zA-Z0-9_-]+$`; an invalid tag rejects the whole append. Omit or `[]` if none.
- `noteId` — the step-4 note id (lets the card open the note). This skill always creates a note, so always set it.

### 6. Report

Read `id` from the append `--json` and report it — e.g. "Brief saved as timeline entry `<id>`, pinned in your sidebar." The append is synchronous and immediately listable.

## Scope boundary

Ends after reporting the id — it only reads, synthesizes, and persists the `brief` entry. No delivery, dispatch, or UI wiring.

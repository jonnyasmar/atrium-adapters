---
name: atrium-create-update
description: "Synthesize an audience-shaped status update (Shipped / In Flight / Watching / Next) from the workspace timeline + open tasks and persist it as a typed `update` timeline entry. Use when the user wants a shareable progress update for a specific audience (a client, a teammate, a stakeholder) or invokes /atrium-create-update — it reads recent activity and writes one update framed for that audience. Delivery to that audience is a separate step, not part of this skill."
version: "0.1.0"
---

# atrium-create-update — synthesize an audience-shaped status update

Turn the workspace recent **timeline** plus its **open tasks** into a **status update** framed for a named audience (a client, a teammate, a stakeholder). It's persisted as a typed `update` timeline entry. atrium runs no LLM — *you* read the source, write the audience-shaped narrative, and persist it via the CLI.

Confirm any flag with `"$ATRIUM_CLI_PATH" <cmd> --help` before guessing — the CLI is the source of truth.

## Inputs

| Flag | Meaning | Default |
|---|---|---|
| `--audience <name>` | Who the update is for (shapes tone + framing) | **ask the user** if absent |
| `--scope <S>` | Canonical scope string to read + write at | the workspace scope `workspace:<workspaceId>` from `context` |
| `--since <RFC3339>` | How far back to read (a concrete instant — resolve relative requests first) | 7 days back |

If `--audience` is absent, **ask the user who this update is for** before synthesizing — the audience changes what you surface and how you frame it.

## Synthesis flow

### 1. Resolve scope

```bash
"$ATRIUM_CLI_PATH" context --json
```

Read **`workspaceId`** — needed for both `--scope` and the **required** `--workspace` on append. Use a caller-passed `--scope` verbatim; otherwise default to `workspace:<workspaceId>`. Deeper scopes (`room:`/`pane:`/`worktree:<ws>/…`) are opt-in via `--scope`.

### 2. Read the source data

Resolve the read window to a concrete RFC3339 instant first (`--since` takes an instant, not a relative duration like `7d`):

```bash
SINCE=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)   # macOS  (Linux: date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
```

```bash
"$ATRIUM_CLI_PATH" timeline list --json --scope "workspace:<workspaceId>" --since "$SINCE"
"$ATRIUM_CLI_PATH" task list --json
```

**Collect the `id` of every timeline entry you draw from** — they become `synthesizedFrom.eventIds`.

### 3. Synthesize — summary, sentinel, then four sections

Structure the text as **summary → sentinel → detail**, in exactly this order:

```markdown
<1–3 sentence, high-signal summary of the update>

<!-- more -->

## Shipped

…

## In Flight

…

## Watching

…

## Next

…
```

The `<!-- more -->` line is an HTML comment (invisible when rendered) where the timeline card splits summary from detail. The four sections: **Shipped** (done and landed — merged work, completed tasks, released changes), **In Flight** (actively in progress now), **Watching** (risks, blockers, open questions, decisions needed), **Next** (what's planned / what the audience can expect). Frame tone and detail for the `--audience` (a client update is outcome-focused and light on internals; a teammate update can be more technical). Derive contents from the timeline and `task list`.

This one text is consumed in **two cuts**: the backing **note** (step 4) holds the full prose; the timeline **`--body`** (step 5) holds **only the summary** (the text above the sentinel). The card shows the summary; clicking it opens the note.

### 4. Create the backing note (full prose)

Markdown notes have **no `--body` flag** (that's canvas/html only) — create from `--title`, then write the body separately. Capture `noteId` from the `--json` (`{"noteId":"<uuid>",…}`):

```bash
NOTE_ID=$("$ATRIUM_CLI_PATH" note new --title "<one-line update summary>" \
  --type markdown --source agent --workspace "<workspaceId>" --json | jq -r '.noteId')

printf '%s' "<the full four-section update>" | "$ATRIUM_CLI_PATH" note write "$NOTE_ID"
```

Note **title** = the one-line summary (same string as the timeline `--title`); note **body** = the full prose (summary + sentinel + four sections). `note write` takes `--content`, `--from-file`, or piped stdin — **don't** pass it `--source` (rejected; the note already carries `source: agent` from `note new`).

### 5. Persist — one `timeline append`

```bash
"$ATRIUM_CLI_PATH" timeline append \
  --workspace "<workspaceId>" --kind update --scope "workspace:<workspaceId>" \
  --title "<one-line update summary>" \
  --body "<the SUMMARY only — text above the <!-- more --> sentinel>" \
  --metadata-json "{\"audience\":\"<name>\",\"publishedTo\":[],\"synthesizedFrom\":{\"eventIds\":[\"<id1>\",\"<id2>\"]},\"tags\":[\"audience:<name>\"],\"noteId\":\"$NOTE_ID\"}" \
  --json
```

`--workspace` is **required** (no implicit current workspace). `--kind update` matches the timeline kind verbatim. `--metadata-json` is passed through **verbatim** — the JSON you write **is** the wire shape (the bare `UpdateMeta` below; atrium doesn't reshape it). Keep `--body` to the summary only — the full prose lives solely in the note (duplicating it bloats storage, goes stale on note edits, and double-indexes FTS).

**`UpdateMeta`:**

```json
{
  "audience": "<name>",
  "publishedTo": [],
  "synthesizedFrom": { "eventIds": ["<timeline id>", "..."] },
  "tags": ["audience:<name>"],
  "noteId": "<note id from step 4>"
}
```

- `audience` — the audience name. **Omit this key entirely** if the user truly gave no audience (don't write `"audience": ""`).
- `publishedTo` — **always `[]`** here. It records where the update was delivered; appending to it is a separate later step (see Scope boundary). Never pre-populate it.
- `synthesizedFrom` carries **only** `eventIds` (+ optional `"label"`) — nothing else. The audience lives at the top-level `audience` field, not inside `synthesizedFrom`.
- `tags` — `<ns>:<value>` strings embedded here so `timeline list --tag` finds the row (e.g. `audience:chris`). Syntax `^[a-z][a-z0-9-]*:[a-zA-Z0-9_-]+$`; an invalid tag rejects the whole append. Omit or `[]` if none.
- `noteId` — the step-4 note id (lets the card open the note). This skill always creates a note, so always set it.

### 6. Report

Read `id` from the append `--json` and report it — e.g. "Update for `<audience>` saved as timeline entry `<id>`." The append is synchronous and immediately listable.

## Scope boundary — send-to-agent is NOT part of this skill

Ends after reporting the id. It does **not** send the update to the audience, post it anywhere, or hand it to another agent — `publishedTo` stays `[]`. Delivery (send-to-agent, appending a publish record to `publishedTo`) is wired separately and is out of scope here.

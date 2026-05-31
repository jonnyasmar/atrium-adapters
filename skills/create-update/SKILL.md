---
name: create-update
description: "Synthesize an audience-shaped status update (Shipped / In Flight / Watching / Next) from the workspace timeline + open tasks and persist it as a typed `update` timeline entry. Use when the user wants a shareable progress update for a specific audience (a client, a teammate, a stakeholder) or invokes /create-update — it reads recent activity and writes one update framed for that audience. Delivery to that audience is a separate step, not part of this skill."
version: "0.1.0"
---

# create-update — synthesize an audience-shaped status update

You are running inside **atrium**. This skill turns the workspace's recent **timeline** plus its **open tasks** into a **status update** framed for a named audience (a client, a teammate, a stakeholder). The update is persisted as a typed `update` entry on the timeline.

atrium itself runs **no LLM**. The synthesis is *your* job: you read the source data, write the audience-shaped narrative, and persist it through the CLI. There is no atrium-side model call.

## The golden rule: discover via `--help`

This skill names the exact flags it depends on, but the CLI is the only source of truth that can't drift. Before invoking a subcommand whose flags you're unsure of, confirm them:

```bash
"$ATRIUM_CLI_PATH" context --help
"$ATRIUM_CLI_PATH" timeline list --help
"$ATRIUM_CLI_PATH" timeline append --help
"$ATRIUM_CLI_PATH" note new --help
"$ATRIUM_CLI_PATH" note write --help
"$ATRIUM_CLI_PATH" task list --help
```

Do not guess flag names — check.

## Inputs

| Flag | Meaning | Default |
|---|---|---|
| `--audience <name>` | Who the update is for (shapes tone + framing) | **ask the user** if absent |
| `--scope <S>` | Canonical scope string to read + write at | the **workspace scope** `workspace:<workspaceId>` resolved from `context` |
| `--since <RFC3339>` | How far back to read the timeline (a concrete RFC3339 timestamp — resolve relative requests like "7 days" to an instant first) | 7 days back (an update covers the recent reporting window) |

If `--audience` is not supplied, **ask the user who this update is for** before synthesizing — the audience changes what you surface and how you frame it.

## The six-step synthesis flow

Do these in order.

### 1. Resolve scope

```bash
"$ATRIUM_CLI_PATH" context --json
```

Read **`workspaceId`** from the JSON — you need it for the `--scope` value and the **required** `--workspace` flag on append.

- If the caller passed `--scope <S>`, use it verbatim.
- Otherwise build the **workspace scope** `workspace:<workspaceId>` (workspace UUID, no further path). Deeper scopes (`room:<ws>/<room>`, `pane:<ws>/<pane>`, `worktree:<ws>/<wt>`) are opt-in via `--scope`.

### 2. Read the source data

First **resolve the read window to a concrete RFC3339 timestamp**. `timeline list --since` accepts an **RFC3339 / ISO-8601 instant only** — it does **not** parse relative durations like `7d` (that relative syntax belongs to the separate `edits --since` command, not here). So compute "now minus 7 days" as a literal RFC3339 timestamp before reading:

```bash
SINCE=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)   # macOS; an update covers the recent reporting window
# (Linux: SINCE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ). Or compute the instant yourself.)
```

Then read:

```bash
"$ATRIUM_CLI_PATH" timeline list --json --scope "workspace:<workspaceId>" --since "$SINCE"
"$ATRIUM_CLI_PATH" task list --json
```

**Collect the `id` of every timeline entry you draw from** — those go into `synthesizedFrom.eventIds`. `timeline list --since` takes a **concrete RFC3339 timestamp** (e.g. `2026-05-23T00:00:00Z`), not a relative duration; confirm the flag shape with `"$ATRIUM_CLI_PATH" timeline list --help` if unsure.

### 3. Synthesize the update — summary, sentinel, then four sections

**Lead with a scannable summary, then a sentinel, then the detail.** The synthesis text must be structured in exactly this order:

1. A **1–3 sentence, high-signal summary** — the gist of the update, written so a reader scanning the timeline card sees what matters without expanding it. This comes **first**.
2. A line containing **exactly** the sentinel `<!-- more -->` (an HTML comment — invisible in rendered markdown; the timeline card splits on it to show summary vs. detail).
3. The **full detail**: the four sections below.

```markdown
<one-to-three-sentence summary of the update>

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

The four detail sections, in this order:

- **Shipped** — what's done and landed since the last update (merged work, completed tasks, released changes).
- **In Flight** — what's actively in progress right now.
- **Watching** — risks, blockers, open questions, things that need a decision.
- **Next** — what's planned next / what the audience can expect.

Frame the tone and detail for the `--audience`: a client update is outcome-focused and light on internals; a teammate update can be more technical. Derive section contents from the timeline (commits, agent work, prior syntheses) and `task list` (open vs. done tasks).

**This exact `summary → <!-- more --> → detail` shape is the prose you reuse verbatim** for both the backing note body (step 4) and the timeline `--body` (step 5). Write it once, here, in this order.

### 4. Create the backing note — holds the full update prose

The update prose lives in a real markdown **note** so the user can click the synthesis card open and read it. Create the note FIRST, capture its id, then carry that id into the timeline append in step 5.

`note new` creates a markdown note from `--title` only — for markdown there is **no** `--body` flag (that's canvas/html only), so you write the body in a second call with `note write <id>`. Capture the new note's id from the `--json` output, which is `{"noteId":"<uuid>","meta":{…},"paneId":null}`:

```bash
NOTE_ID=$("$ATRIUM_CLI_PATH" note new \
  --title "<one-line update summary>" \
  --type markdown \
  --source agent \
  --workspace "<workspaceId>" \
  --json | jq -r '.noteId')

printf '%s' "<the four-section update>" | "$ATRIUM_CLI_PATH" note write "$NOTE_ID"
```

Notes:

- The note **title** = the update's one-line summary (the same string you pass as the timeline `--title`). The note **body** = the full four-section update markdown (the same prose you pass as the timeline `--body`).
- `note write` reads the body from `--content`, `--from-file <path>`, or piped stdin. Piping (`printf … | note write "$NOTE_ID"`) avoids shell-quoting a multi-paragraph body; `--from-file` is the alternative if you wrote the prose to a temp file. Do **not** pass `--source` to `note write` — it's rejected ("not yet supported by the storage layer"); the note already carries `source: agent` from `note new`.
- `--source agent` on `note new` marks the note as agent-authored. `--workspace` is the `workspaceId` from step 1.
- Confirm the exact flags with `"$ATRIUM_CLI_PATH" note new --help` / `note write --help` if unsure.

### 5. Write the entry — a SINGLE `timeline append`

Persist the update with exactly this flag contract (the as-built Story 76-4 surface — do **not** invent flags). Include the `noteId` from step 4 in the metadata:

```bash
"$ATRIUM_CLI_PATH" timeline append \
  --workspace "<workspaceId>" \
  --kind update \
  --scope "workspace:<workspaceId>" \
  --title "<one-line update summary>" \
  --body "<the four-section update>" \
  --metadata-json "{\"audience\":\"<name>\",\"publishedTo\":[],\"synthesizedFrom\":{\"eventIds\":[\"<id1>\",\"<id2>\"]},\"tags\":[\"audience:<name>\"],\"noteId\":\"$NOTE_ID\"}" \
  --json
```

Contract notes:

- `--workspace <workspaceId>` is **REQUIRED**.
- `--kind update` — kebab-case, matches the timeline's `update` synthesis kind verbatim.
- `--scope` — the canonical scope string from step 1.
- `--metadata-json` is passed through **verbatim**. The JSON you write **is** the wire shape; it must be the bare `UpdateMeta` object below.

**`UpdateMeta` — the exact bare shape:**

```json
{
  "audience": "<name>",
  "publishedTo": [],
  "synthesizedFrom": { "eventIds": ["<timeline id>", "..."] },
  "tags": ["audience:<name>"],
  "noteId": "<note id from step 4>"
}
```

- `audience` — the audience name. **Omit this key entirely** if the user truly provided no audience (don't write `"audience": ""`).
- `publishedTo` — **always an empty array `[]`** here. It records where the update was delivered; appending to it is a *separate* later step (see "Scope boundary"). Never pre-populate it.
- `synthesizedFrom` carries **only** `eventIds` (the timeline `id`s from step 2) and an optional `"label"`. Write **nothing else** inside it — no `timeRange`, no `scope`, no `taskIds`. The audience lives at the top-level `audience` field, **not** inside `synthesizedFrom`.
- `tags` — `<namespace>:<value>` strings embedded in the payload so `timeline list --tag` finds the row (e.g. `audience:chris`, `topic:weekly`). Tag syntax `^[a-z][a-z0-9-]*:[a-zA-Z0-9_-]+$`; an invalid tag rejects the whole append. Omit or `[]` if none.
- `noteId` — the id of the backing note from step 4. This is what lets the synthesis card open the note. Optional on the wire (omit it if you genuinely created no note), but this skill always creates one, so always set it.

### 6. Report the new entry id

Read `id` from the `--json` append response and report it to the user — e.g. "Update for `<audience>` saved as timeline entry `<id>`." The append is synchronous and immediately listable.

## Scope boundary — send-to-agent is NOT part of this skill

**This skill ends after reporting the id.** It does **not** send the update to the audience, post it to any external surface, or hand it to another agent. `publishedTo` stays `[]`. Delivery (send-to-agent on updates, appending a publish record to `publishedTo`) is wired separately and is out of scope here — do not attempt it from this skill.

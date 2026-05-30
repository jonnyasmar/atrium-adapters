---
name: create-brief
description: "Synthesize a project brief from the workspace timeline + open tasks and persist it as a typed `brief` timeline entry, pinned in the sidebar. Use when the user returns to a workspace cold and asks 'what is this / where did I leave off', wants a fresh orientation, or invokes /create-brief — it reads the recent timeline and open work and writes a single cold-resume brief the user can pick back up from."
version: "0.1.0"
---

# create-brief — synthesize a cold-resume project brief

You are running inside **atrium**. This skill turns the workspace's recent **timeline** (the activity substrate: prompts, commits, task changes, agent messages, prior syntheses) plus its **open tasks** into a single **project brief** — a cold-resume orientation a returning user (or agent) can pick the project back up from. The brief is persisted as a typed `brief` entry on the timeline and pinned in the sidebar.

atrium itself runs **no LLM**. The synthesis is *your* job: you read the source data, write the narrative, and persist it through the CLI. There is no atrium-side model call.

## The golden rule: discover via `--help`

This skill names the exact flags it depends on, but the CLI is the only source of truth that can't drift. Before you invoke a subcommand whose flags you're unsure of, confirm them:

```bash
"$ATRIUM_CLI_PATH" context --help
"$ATRIUM_CLI_PATH" timeline list --help
"$ATRIUM_CLI_PATH" timeline append --help
"$ATRIUM_CLI_PATH" task list --help
```

Do not guess flag names — check.

## Inputs

| Flag | Meaning | Default |
|---|---|---|
| `--scope <S>` | Canonical scope string to read + write at | the **workspace scope** `workspace:<workspaceId>` resolved from `context` |
| `--since <RFC3339>` | How far back to read the timeline (a concrete RFC3339 timestamp — resolve relative requests like "30 days" to an instant first) | 30 days back (a brief takes a wide view of where the project has been) |

`--scope` is an override the verb-cluster (and power users) can pass to narrow to a room, pane, or worktree. When it's absent, default to the workspace scope.

## The five-step synthesis flow

Do these in order.

### 1. Resolve scope

```bash
"$ATRIUM_CLI_PATH" context --json
```

This prints the caller's context as JSON: `workspaceId`, `roomId`, `paneId`, `adapterType`, `cwd`, etc. Read **`workspaceId`** from it — you need it for both the `--scope` value and the **required** `--workspace` flag on append.

- If the caller passed `--scope <S>`, use it verbatim.
- Otherwise build the **workspace scope**: `workspace:<workspaceId>` (the workspace UUID, no further path). This is the safe broad default; deeper scopes (`room:<ws>/<room>`, `pane:<ws>/<pane>`, `worktree:<ws>/<wt>` — workspace UUID always first) are opt-in via `--scope`.

`$ATRIUM_PANE_ID` is your pane UUID if you ever need a pane-scope override (`pane:<workspaceId>/$ATRIUM_PANE_ID`).

### 2. Read the source data

First **resolve the read window to a concrete RFC3339 timestamp**. `timeline list --since` accepts an **RFC3339 / ISO-8601 instant only** — it does **not** parse relative durations like `30d` (that relative syntax belongs to the separate `edits --since` command, not here). So compute "now minus 30 days" as a literal RFC3339 timestamp before reading:

```bash
SINCE=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)   # macOS; a brief takes a wide 30-day view
# (Linux: SINCE=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ). Or compute the instant yourself.)
```

Then read the recent timeline at the resolved scope, and the open tasks for cold-resume context:

```bash
"$ATRIUM_CLI_PATH" timeline list --json --scope "workspace:<workspaceId>" --since "$SINCE"
"$ATRIUM_CLI_PATH" task list --json
```

Each timeline entry in the `--json` array carries an `id`, `kind`, `scope`, `title`/`body`, `createdAt`, and (where present) a typed `payload`. **Collect the `id` of every entry you actually draw from** — you write those ids into `synthesizedFrom.eventIds` in step 4 (that's the attribution link back to the originals).

`timeline list --since` takes a **concrete RFC3339 timestamp** (e.g. `2026-05-01T00:00:00Z`), not a relative duration. A brief uses a wide window (default 30 days back) because it's orienting the reader to the whole project, not a slice. Confirm the exact flag shape with `"$ATRIUM_CLI_PATH" timeline list --help` if unsure.

### 3. Synthesize the brief

Write a **cold-resume orientation narrative** — assume the reader has zero context. Cover:

- **What this workspace is** — the project, its purpose, the stack, what it's for.
- **Where it left off** — the most recent meaningful activity (last commits, last agent work, last syntheses).
- **What's open** — the open tasks and in-flight threads from `task list` and the recent timeline.

Keep it tight and skimmable. This is the artifact that lands in the pinned-latest slot of the sidebar, so the title should read as a clear orientation line.

### 4. Write the entry — a SINGLE `timeline append`

Persist the brief with exactly this flag contract (the as-built Story 76-4 surface — do **not** invent flags):

```bash
"$ATRIUM_CLI_PATH" timeline append \
  --workspace "<workspaceId>" \
  --kind brief \
  --scope "workspace:<workspaceId>" \
  --title "<one-line orientation>" \
  --body "<the brief narrative>" \
  --metadata-json '{"synthesizedFrom":{"eventIds":["<id1>","<id2>"]},"tags":["scope:project"]}' \
  --json
```

Contract notes:

- `--workspace <workspaceId>` is **REQUIRED** — there's no implicit current workspace for append. Use the `workspaceId` from step 1.
- `--kind brief` — kebab-case, matches the timeline's `brief` synthesis kind verbatim.
- `--scope` — the same canonical scope string you resolved in step 1.
- `--metadata-json` is passed through **verbatim** to the entry's metadata. The JSON you write **is** the wire shape — it must be the bare `BriefMeta` object below. atrium does not reshape or re-key it.

**`BriefMeta` — the exact bare shape:**

```json
{
  "synthesizedFrom": { "eventIds": ["<timeline id>", "..."] },
  "tags": ["scope:project", "topic:onboarding"]
}
```

- `synthesizedFrom` carries **only** `eventIds` (the timeline `id`s from step 2) and an optional `"label": "<string>"`. Write **nothing else** inside it — no `timeRange`, no `scope`, no `taskIds`. Extra keys are dropped on read and are wrong.
- `tags` is an array of `<namespace>:<value>` strings (e.g. `scope:project`, `topic:onboarding`). Embed tags **inside** the metadata payload — `timeline list --tag <t>` filters on the metadata `tags` field, so a tag only finds the row if it's here. Tag syntax is `^[a-z][a-z0-9-]*:[a-zA-Z0-9_-]+$`; an invalid tag rejects the whole append. Omit `tags` (or use `[]`) if you have none.
- You *may* also pass repeatable `--tag <ns:value>` flags, but the canonical pattern is to embed tags in `--metadata-json` as above.

### 5. Report the new entry id

The `--json` append echoes the created row, including its assigned `id`. Read `id` from that response and report it to the user — e.g. "Brief saved as timeline entry `<id>`, pinned in your sidebar." The append is synchronous and immediately listable; no polling is needed.

## Scope boundary

This skill **ends after reporting the id**. It does not send the brief anywhere, dispatch other skills, or wire UI buttons. It only reads, synthesizes, and persists the `brief` entry.

---
name: create-recap
description: "Synthesize a time-bounded recap of what happened in a workspace over a window (default the last 7 days) from the timeline + open tasks, and persist it as a typed `recap` timeline entry. Use when the user wants a 'what happened this week / since <date>' summary or invokes /create-recap — it reads the timeline for the window and writes one recap narrative tagged with the exact time range it covers."
version: "0.1.0"
---

# create-recap — synthesize a time-bounded recap

You are running inside **atrium**. This skill turns the workspace's **timeline** over a specific time window (default: the last 7 days) plus its **open tasks** into a **recap** — a narrative of what happened in that window. The recap is persisted as a typed `recap` entry on the timeline, tagged with the exact range it covers.

atrium itself runs **no LLM**. The synthesis is *your* job: you read the source data, write the narrative, and persist it through the CLI. There is no atrium-side model call.

## The golden rule: discover via `--help`

This skill names the exact flags it depends on, but the CLI is the only source of truth that can't drift. Before invoking a subcommand whose flags you're unsure of, confirm them:

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
| `--since <RFC3339>` | Start of the recap window (a concrete RFC3339 timestamp) | 7 days back (last 7 days) |
| `--until <RFC3339>` | End of the recap window (a concrete RFC3339 timestamp) | now |
| `--scope <S>` | Canonical scope string to read + write at | the **workspace scope** `workspace:<workspaceId>` resolved from `context` |

A user may *ask* for the window in relative terms ("the last 7 days", "since last Monday"). **Resolve that to concrete RFC3339 timestamps before reading** — `timeline list --since`/`--until` accept an **RFC3339 / ISO-8601 instant only**, not relative durations like `7d` (that relative syntax belongs to the separate `edits --since` command, not here). When both are absent, recap **the last 7 days**: start = now minus 7 days, end = now. The same resolved start/end feed both the `timeline list` read (step 2) and `RecapMeta.timeRange` (step 4).

## The five-step synthesis flow

Do these in order.

### 1. Resolve scope

```bash
"$ATRIUM_CLI_PATH" context --json
```

Read **`workspaceId`** from the JSON — you need it for the `--scope` value and the **required** `--workspace` flag on append.

- If the caller passed `--scope <S>`, use it verbatim.
- Otherwise build the **workspace scope** `workspace:<workspaceId>`. Deeper scopes (`room:<ws>/<room>`, `pane:<ws>/<pane>`, `worktree:<ws>/<wt>`) are opt-in via `--scope`.

### 2. Read the source data over the window

First **resolve the window to concrete RFC3339 timestamps** — one start instant and one end instant. These same two values drive both the read below and `RecapMeta.timeRange` in step 4. For the default last-7-days window:

```bash
START=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)   # macOS; start = now minus 7 days
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)           # end = now
# (Linux: START=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ); END=$(date -u +%Y-%m-%dT%H:%M:%SZ).)
# If the user passed explicit --since / --until, resolve those to RFC3339 instants instead.
```

Then read exactly that window:

```bash
"$ATRIUM_CLI_PATH" timeline list --json --scope "workspace:<workspaceId>" --since "$START" --until "$END"
"$ATRIUM_CLI_PATH" task list --json
```

`timeline list --since`/`--until` take **concrete RFC3339 timestamps** (e.g. `2026-05-23T00:00:00Z`), not relative durations; confirm the flag shape with `"$ATRIUM_CLI_PATH" timeline list --help` if unsure. **Collect the `id` of every timeline entry you draw from** — those go into `synthesizedFrom.eventIds`.

Keep the resolved `START` / `END` instants — you write them into `RecapMeta.timeRange` in step 4.

### 3. Synthesize the recap

Write a **time-bounded narrative** of what happened in the window: the work that landed, the threads that moved, decisions made, and what's still open at the end of the window. State the window plainly (e.g. "the last 7 days" or the explicit dates) so the reader knows the scope of the recap.

### 4. Write the entry — a SINGLE `timeline append`

Persist the recap with exactly this flag contract (the as-built Story 76-4 surface — do **not** invent flags):

```bash
"$ATRIUM_CLI_PATH" timeline append \
  --workspace "<workspaceId>" \
  --kind recap \
  --scope "workspace:<workspaceId>" \
  --title "<one-line recap summary>" \
  --body "<the recap narrative>" \
  --metadata-json '{"timeRange":["<startIso>","<endIso>"],"synthesizedFrom":{"eventIds":["<id1>","<id2>"]},"tags":["topic:weekly"]}' \
  --json
```

Contract notes:

- `--workspace <workspaceId>` is **REQUIRED**.
- `--kind recap` — kebab-case, matches the timeline's `recap` synthesis kind verbatim.
- `--scope` — the canonical scope string from step 1.
- `--metadata-json` is passed through **verbatim**. The JSON you write **is** the wire shape; it must be the bare `RecapMeta` object below.

**`RecapMeta` — the exact bare shape:**

```json
{
  "timeRange": ["<startIso>", "<endIso>"],
  "synthesizedFrom": { "eventIds": ["<timeline id>", "..."] },
  "tags": ["topic:weekly"]
}
```

- `timeRange` is **camelCase** and is a **two-element `[start, end]` array of ISO-8601 timestamps** — the concrete window you resolved in step 2. The time range lives here at the top level, **not** inside `synthesizedFrom`.
- `synthesizedFrom` carries **only** `eventIds` (the timeline `id`s from step 2) and an optional `"label"`. Write **nothing else** inside it — no `timeRange`, no `scope`, no `taskIds`.
- `tags` — `<namespace>:<value>` strings embedded in the payload so `timeline list --tag` finds the row (e.g. `topic:weekly`). Tag syntax `^[a-z][a-z0-9-]*:[a-zA-Z0-9_-]+$`; an invalid tag rejects the whole append. Omit or `[]` if none.

### 5. Report the new entry id

Read `id` from the `--json` append response and report it to the user — e.g. "Recap of the last 7 days saved as timeline entry `<id>`." The append is synchronous and immediately listable.

## Scope boundary

This skill **ends after reporting the id**. It only reads the window, synthesizes the recap, and persists the `recap` entry — no delivery, no dispatch, no UI wiring.

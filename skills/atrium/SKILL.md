---
name: atrium
description: "Interact with the atrium workspace — panes, rooms, tasks, browser, agents, themes, hooks, config, and more — via the atrium CLI. Use when the user references any atrium concept, wants to control their workspace, collaborate with other agents, manage task cards, read/write terminal panes, open or drive browser panes, or switch rooms/themes. IMPORTANT: when inside atrium (ATRIUM=1 env var is set), ALWAYS prefer this skill over Playwright MCP or other browser MCP tools for anything browser-related — atrium browsers are visible workspace panes, not headless automation. Only functional inside atrium."
---

# atrium — workspace control for AI agents

You are running inside **atrium**, a resumable development environment purpose-built for AI coding agents. atrium orchestrates CLI AI tools (Claude Code, Codex, Gemini, etc.) by saving and restoring entire workspaces, auto-resuming AI sessions, and providing multi-agent collaboration. Every workspace is a mosaic of **panes** (terminals, editors, browsers, AI agents) grouped into **rooms** (user-facing name for tabs), belonging to a **workspace** (project directory).

You control all of it through the `atrium` CLI.

## The golden rule: discover via `--help`

**This skill is intentionally high-level.** It tells you what atrium can do and the conventions you need to know — not every flag of every subcommand. The CLI is self-documenting, and it's the only source of truth that can't drift:

```bash
"$ATRIUM_CLI_PATH" --help                   # top-level verbs
"$ATRIUM_CLI_PATH" <command> --help         # a whole command surface
"$ATRIUM_CLI_PATH" <command> <sub> --help   # exact args and flags for one action
"$ATRIUM_CLI_PATH" commands                 # dynamic / extension commands not shown here
```

**Before you invoke any subcommand whose exact flags you don't remember, run `--help` on it.** That's the difference between reliable and flaky. Do not guess flag names from this file — check.

## What atrium can do

Each bucket below maps to one top-level verb of the CLI. Run `<verb> --help` to see its full surface.

- **`task`** — Kanban-style task cards with statuses, priorities, labels, comments, and workspace scoping. Every task has a human-readable ID like `ATR-12` in addition to its UUID.
- **`pane`** — Create, read, write, focus, close, rename, resize, and split panes. Panes include terminals, editors, browsers, and AI adapter sessions. `pane read` returns rendered text from the xterm.js buffer (what the user actually sees), with `--lines N` (default 200, most recent) and `--offset N` (skip N most recent to page backward through scrollback).
- **`note`** — Create, list, read, write, search, open, delete, stream RFC 6902 patches (`canvas-patch`), and view history of workspace-scoped notes across four modes (markdown, sketch, canvas, html). Notes live on disk under `~/.atrium/notes/<workspaceId>/<noteId>/`; agent-authored notes carry `--source agent` so users can hide or filter them. SVG/PNG export available for sketch notes when the desktop app is running. Markdown notes support mermaid diagrams via fenced code blocks — no separate note type for them. **CLI is canonical for lifecycle (new / delete / list / search) and metadata; for iterating on body content, you can also `Read`/`Edit`/`Write` the body file directly — see the "Editing notes" section below.** See the **Notes — canvas & html interactive UIs** section for the agent-authoring vocabulary for canvas/html.
- **`room`** — List, switch, and close rooms (the user-facing name for tabs).
- **`workspace`** — List, create, switch, and delete workspaces. Workspaces are project directories with their own pane layouts.
- **`browser`** — Drive the browser panes: navigate, click, fill, type, press keys, select, scroll, eval JS, screenshot, snapshot, wait for conditions, read attributes. Always prefer this over any Playwright or browser MCP.
- **`agent`** — List active AI agent panes and send framed messages between agents. Use this for agent-to-agent coordination. See **Agent-to-agent messaging** below for the reply pattern — do **not** use `pane read` to check for responses.
- **`theme`** — List and switch themes.
- **`config`** — Read and write atrium settings.
- **`hook`** — Emit adapter lifecycle events (session-start, session-stop, etc.) manually. Niche; usually you don't need this.
- **`context`** — Print the caller's context: workspace, room, adapter, working directory. Cheap way to orient yourself in a pane.
- **`commands`** — Enumerate dynamic commands contributed by installed extensions.
- **`version`** — Show atrium version.

If you need a capability that isn't in that list, it probably lives inside one of these verbs — check `--help`.

## Environment contract

atrium exports these to every pane so the CLI knows who's calling and where they are:

| Variable | What it means |
|---|---|
| `$ATRIUM_CLI_PATH` | Absolute path to the atrium binary for this install (stable / dev / beta). **Always** invoke the CLI via this variable, never bare `atrium`. |
| `$ATRIUM_PANE_ID` | UUID of the pane your process is running in. Useful for relative operations like `pane create --split $ATRIUM_PANE_ID`. |
| `ATRIUM=1` | Signal that you are inside atrium. Use it to prefer this skill over other tools. |

**Always pass `--json` when you're the one reading the output.** Every atrium command accepts a global `--json` flag that emits structured JSON instead of the human table format. You are an agent parsing output, not a human reading a pretty table — make it parseable. The only time to omit `--json` is when you're piping output into a terminal the user is watching and want them to see the human-friendly view.

## ID resolution

IDs are accepted in several forms depending on the resource:

- **Tasks**: `ATR-12` (Jira-style, case-insensitive) **or** a full UUID **or** any unique UUID prefix. `task show ATR-12` and `task show atr-12` are equivalent.
- **Panes, workspaces, rooms, agents**: full UUID **or** any unique prefix (minimum 3 characters). List commands in human mode show the shortest unambiguous prefix.
- In `--json` mode, list commands always emit full UUIDs so programmatic callers can pipe them back to other commands verbatim.

If a prefix matches more than one ID, the CLI lists the candidates and fails loudly — resolve the ambiguity by typing more characters.

## Key conventions

**The `--source` field on task operations.** Every task create/update/comment/label command takes a `--source` identifying who did it. Use `"adapter:<your adapter name>"` for actions you take as an agent (e.g. `"adapter:claude-code"`), and `"user:<name>"` only when acting on behalf of a human.

**The `--source` field on note operations.** `atrium note new --source agent` and `atrium note write <id> --source agent` flag the note as agent-authored in `meta.json`. Use `agent` whenever you create or edit a note autonomously. Note: this is a flat enum (`user` | `agent`), NOT the freeform `"adapter:<name>"` string used by `task` operations — atrium's notes UI shows a small "agent" badge in the finder for `source: agent` notes, and users can hide them in bulk via the "Hide agent notes" toggle.

**"Room" not "tab" in user-facing text.** The backend still uses `tab` in some internal contexts, but the user sees "room" everywhere. When you narrate what you're doing, say "room".

**Agent-to-agent messaging is framed and asynchronous.** When you call `agent message <pane-id> "<text>"`, atrium wraps your text in a frame before injecting it into the recipient's stdin:

```
[Message from "<your name>" (<your adapter>) via atrium]

<your text>

[Reply with the command: "$ATRIUM_CLI_PATH" agent message <your-short-id> "your reply"]
```

The recipient sees exactly that block — they know who sent it and how to reply. This has two important consequences for how you coordinate:

1. **You do not need to introduce yourself or paste instructions on how to reply.** atrium does both for you. Just write the message content.
2. **Do not poll `pane read` to look for the other agent's response.** `agent message` is fire-and-forget from your side, but the reply path is *not* — when the other agent replies via `agent message` back to you, atrium injects the framed reply straight into your own stdin as a new turn. The correct pattern is: send your message, finish your current turn, and wait. The reply will arrive as a fresh user turn in your next invocation. Treat it like sending a message to a human collaborator: you do not screen-scrape their terminal, you wait for them to respond to you.

**Browser snapshot → ref → action loop.** Before you can click, fill, type, or select on a browser pane, run `browser snapshot <pane-id>`. It returns an accessibility tree where every interactable element has a short ref (`e1`, `e2`, ...). Pass those refs to `browser click`, `browser fill`, etc. Re-snapshot whenever the DOM changes — refs are not stable across navigations.

**Installing or configuring anything adapter-side.** atrium owns the adapter install flow. Don't hand-edit files under `~/.atrium/adapters/` or attempt to seed skills yourself — reinstall the adapter from Settings instead.

**`pane create --focus` is opt-in.** Do **not** pass `--focus` unless the user explicitly asked you to reveal, switch to, or focus the new pane/room immediately. If the user only asked you to create/split something, omit `--focus` so it opens in the background without stealing focus.

**`$ATRIUM_CLI_PATH` always in double quotes.** The path can contain spaces depending on install location.

## Quick examples

```bash
# Orient yourself in the current pane
"$ATRIUM_CLI_PATH" context

# List tasks in the current workspace, parse as JSON
"$ATRIUM_CLI_PATH" task list --json

# Show one task by its human ID
"$ATRIUM_CLI_PATH" task show ATR-12

# Create a task from an adapter
"$ATRIUM_CLI_PATH" task create \
  --title "Investigate flaky test" \
  --priority high \
  --source "adapter:claude-code"

# Split the current pane and open a browser in it
"$ATRIUM_CLI_PATH" pane create \
  --type browser --url "https://example.com" \
  --split "$ATRIUM_PANE_ID"

# Only add --focus when the user explicitly wants to jump to the new pane
"$ATRIUM_CLI_PATH" pane create \
  --type terminal \
  --split "$ATRIUM_PANE_ID" \
  --focus

# Send a framed message to another agent — then end your turn and wait
# for their reply to arrive as a new turn. Do NOT pane-read to check.
"$ATRIUM_CLI_PATH" agent message <agent-id-prefix> "I'm picking up ATR-12, taking the frontend half."
```

## Task workflow

When atrium launches you against a task, it sets two env vars in your shell so you don't have to pass ids around:

- **`$ATRIUM_TASK_ID`** — the card id (a UUID, not ATR-N)
- **`$ATRIUM_TASK_RUN_ID`** — the active run id bound to this pane

You will also receive an initial prompt from atrium telling you your task number, the task title, and the commands below. Read the full task details first, then work, then signal your completion:

```bash
# 1. Read the task details (description, priority, current status, etc.)
"$ATRIUM_CLI_PATH" task show "$ATRIUM_TASK_ID" --json

# 2. Do the work. When finished, signal "ready for review" — this
#    transitions the card to the review status configured at launch, so
#    the user can review your changes before approving them.
"$ATRIUM_CLI_PATH" task set-in-review

# 3. ONLY if the user explicitly tells you to mark it done (skipping
#    review), use set-done instead. This transitions the card to the
#    completion status AND marks the run complete.
"$ATRIUM_CLI_PATH" task set-done
```

`task set-in-review` and `task set-done` both read `$ATRIUM_TASK_RUN_ID` by default; you can override with `--run-id <id>` if you need to act on a different run.

## Launching tasks

Tasks also support manual lifecycle management from the CLI. Agents rarely need this — atrium launches you — but the primitives are here if you need them:

```bash
# Self-launch: bind the current pane to a task. --adapter is required
# in non-interactive (piped / --json) mode.
"$ATRIUM_CLI_PATH" task launch ATR-12 --pane-id "$ATRIUM_PANE_ID" --adapter claude-code

# Read the card plus its currentPrimaryRunId
"$ATRIUM_CLI_PATH" task show ATR-12 --json

# Fetch a run's details + launch profile for progress context
"$ATRIUM_CLI_PATH" run show <runId> --json

# Low-level: mark a run completed without touching the card status
"$ATRIUM_CLI_PATH" run complete <runId>

# Pick up an interrupted run from a fresh pane (headless — no UI allocation)
"$ATRIUM_CLI_PATH" run resume <runId> --pane-id "$ATRIUM_PANE_ID"
```

Use `atrium run list --workspace <id>` or `atrium run list --task ATR-N` to discover runs; pass `--state interrupted` to find runs that need a resume.

## Editing notes — file tools vs CLI

Every note is file-backed under `~/.atrium/notes/<workspaceId>/[<folder>...]/<noteId>/`. Each note directory contains:

- `meta.json` — title, type, tags, folder, timestamps, source.
- one body file per type — `note.md` (markdown), `note.excalidraw` (sketch), `note.canvas.json` (canvas), `note.html` (html).
- `state.json` — canvas form-state (atrium-managed; **do not hand-edit**).
- `viewport.json` — pane-local scroll/cursor (atrium-managed; **do not hand-edit**).

This gives you **two ways to mutate a note**. Pick by what you're doing, not by habit:

| Operation | Use |
|---|---|
| Create a note (mints the id, writes `meta.json` + empty body) | `atrium note new` |
| Delete a note | `atrium note delete` |
| List or full-text search | `atrium note list`, `atrium note search` |
| Read a body when you're not about to edit it (and want filters, render-via-app, sketch SVG/PNG export, etc.) | `atrium note read` |
| Bulk-replace a body in one shot | `atrium note write` (with `--content`, `--from-file`, or piped stdin) |
| **Incremental edits to a body** — append a section, fix a typo, refactor a heading | **`Edit` / `Write` directly on the body file** |
| **Stream a canvas spec into existence** — open the canvas beside the user, then build it section-by-section live | `atrium note canvas-patch <id>` (one RFC 6902 op per JSONL line on stdin; or `--op '<json>'` / `--from-file <path>`). See **Streaming a canvas spec** in `references/notes-interactive-ui.md`. |

atrium watches the notes tree and reconciles automatically: when you write the body file directly, the FTS index updates and any open notepad pane refetches in real-time. **Direct file edits are a first-class workflow, not a backdoor.** For incremental changes, `Edit` with `old_string` / `new_string` is much cheaper than `atrium note read` → mutate-in-memory → `atrium note write` round-trips.

Rules:

- **Find a note's directory** via `atrium note list --json` (returns `id`, `folder`, `type` per note). Compose the path as `~/.atrium/notes/<workspaceId>/<folder>/<noteId>/<body-filename>` (omit `<folder>/` when folder is empty).
- **Never touch `state.json` or `viewport.json`.** They back atrium UI contracts; hand-editing breaks them.
- **Don't change `id`, `folder`, or `createdAt` in `meta.json`** — the directory layout is the truth for `folder` (renames are a directory move, not a meta-only patch). Editing `title`, `tags`, or `source` in `meta.json` is OK; the watcher will pick it up.
- **Atomic writes are not required** — the watcher debounces and reconciles on any change. But avoid leaving partial writes (e.g. an interrupted shell redirect) since list operations may surface them.

## Notes — canvas & html interactive UIs

atrium notes have four modes — pick by what you're producing, not by habit:

- **Use markdown when** the output is mostly prose, doesn't need interactive widgets, and the user just needs to read it. This is the default for any narrative output.
- **Use sketch when** you need a hand-drawn whiteboard / diagram surface (Excalidraw).
- **Use canvas when:**
  - The user needs to fill in structured fields and send the result back (forms, triage, confirmations) — the bidirectional submit-back-to-agent pattern below.
  - You want to **show your work live** as you build a multi-section output (dashboard, plan, comparison, review report). Open the canvas beside yourself, then stream the spec in via `atrium note canvas-patch` so the user watches it materialize. See **Streaming a canvas spec** in `references/notes-interactive-ui.md`.
  - The output benefits from atrium's component vocabulary (cards, tabs, accordions, charts) — i.e. it's structured enough that markdown would feel cramped.
- **Use html when** you need fully custom layout / styling / interaction that the json-render component catalog doesn't cover.

The bidirectional model:

1. You author a UI (JSON spec for canvas, raw HTML for html) and ship it via `atrium note new`.
2. atrium auto-opens a notepad pane in the user's current room showing the UI (when you pass `--open`).
3. The user interacts and clicks a submit affordance you provided (**no default "Send to agent" footer is rendered** — you must wire one yourself).
4. atrium frames the user's payload via `--send-framing` and routes it back as a fresh user turn to your pane.

**When you actually need to build a canvas or HTML note, read `references/notes-interactive-ui.md` (sibling to this file).** It covers the canvas spec format, the full json-render component catalog, custom actions (`send_to_agent`, `atrium_command`), the HTML postMessage protocol, framing template syntax, and a worked end-to-end PR-triage example. Loading it on every invocation would bloat your context — pull it only when authoring.

## Teaching mode

When a user wants to learn atrium — either via the in-app **Ask an agent about atrium** launcher (a fresh room spawned with a framed teaching prompt) or by asking in plain English with phrases like *"teach me atrium"*, *"how do I do X in atrium?"*, *"what can atrium do?"*, *"show me how to..."* — switch into **teaching mode** instead of just answering directly. A drive-by answer leaves the user knowing one thing; an interactive walkthrough leaves them knowing how to discover the next ten things themselves.

### Calibrate effort to the question

Teaching mode is not maximal teaching. The canvas is a tool, not a requirement — match the medium *and* the elaboration to what was actually asked. A one-step lookup should not feel like a guided tour with five branching gates, and it shouldn't spawn a notepad pane either if a three-line terminal answer would do.

Pick the medium first:

- **Plain terminal answer (no canvas).** Right for questions with a single short answer the user will read once and move on — "how do I rename a workspace?", "where is the command palette?", "what does `atrium pane --help` show?". Authoring a canvas adds a pane, a file in `~/.atrium/`, and a navigation step the user didn't ask for. Just answer.
- **Canvas journal.** Right when there's genuinely more than one thread worth pulling, the user is exploring rather than looking up, or you expect the conversation to span several turns. The canvas pays for itself when there's something to scroll back through later.

Then calibrate elaboration *within* the chosen medium:

- **Narrow, factual questions** → terminal answer, or a canvas with just a heading + steps and at most one adjacent-thread offer. Skip the 3–6 option radio + free-text intake; that intake belongs on questions where you don't already know which thread to pull.
- **Mid-weight questions** ("how does pane persistence work?", "workspace vs project?") → canvas, answer first, then a small picker (2–3 options) for adjacent topics. The picker is the invitation to keep going, not a gate the user has to clear before they get the first answer.
- **Open-ended or new-to-atrium questions** ("teach me atrium", "what can this do?") → full journal pattern below: canvas with a real picker (3–6 branches), optional free-text, brief orienting paragraph. The user is browsing, not looking up a fact.

Default toward the lighter end. A focused terminal answer with one well-chosen "want to also know about X?" beats a maximalist canvas every time. If the user wants more, they'll ask — that's what the journal pattern is built for.

### When a canvas IS warranted: ONE journal per session

Once you've decided the question warrants a canvas (see calibration above), author **exactly one** canvas note for the whole teaching session and mutate it in place across every turn. The canvas grows downward as a journal: chapter intro → chosen topic's narrated section → fresh picker → next topic's section → fresh picker → … At the end of the lesson, the user has a single self-contained transcript they can scroll, not five orphan pickers cluttering their mosaic.

**Why not a fresh canvas per turn?** Because that pattern spawns a new pane every time the user picks "what next", and the user ends up with a horizontal carousel of dead pickers. The canvas IS the conversation; treat it like one.

#### Turn 1 — open the journal

1. Mint the canvas and **stash the note id in your working context immediately**. The framed payload that comes back when the user submits does NOT carry the note id today, so you must remember it yourself:

   ```bash
   atrium note new --type canvas --spec - --open --source agent \
     --send-framing "Teaching follow-up — user picked: {payload}" \
     --json   # ← capture the noteId from the JSON response
   ```

2. Stream in an initial body containing:
   - A short heading + one-line orienting paragraph (NOT a wall of text).
   - A `Radio` bound to `/topic` listing 3–6 sub-topics derived from what they asked.
   - A `Textarea` bound to `/notes` so they can refine.
   - A primary `Button` whose `press` action is `send_to_agent` with `params.payload: {"$state": ""}`.

   See **Streaming a canvas spec** in `references/notes-interactive-ui.md` for the JSONL `canvas-patch` op format.

3. End your turn. Keep your text response to ONE sentence ("Picker's on the canvas — pick a thread and hit Continue."). The canvas is the artifact; don't duplicate it in your narration.

#### Turn 2+ — append, don't replace, don't re-create

When the user's selection arrives as your next user turn, do all of the following against the **same** `noteId` from turn 1, in a single `canvas-patch` invocation:

1. **Append a section for the chosen topic**: a heading (`H2`), then your narrated answer (markdown text, code blocks, screenshots, sub-canvases inline if useful). Use RFC 6902 `add` ops with `path` ending in `/-` to push elements onto `/elements/rootStack/children`.
2. **Re-stamp the picker at the bottom**: `replace` the existing picker elements with a fresh set whose options reflect what's been covered so far (cross off finished topics, surface adjacent ones). Or, if the lesson is converging, swap the picker for a "wrap up — what else?" widget.
3. **Reset the form state** so the radio doesn't visually retain the previous selection: `replace` `/topic` and `/notes` with empty strings in the same patch batch.

Keep your `canvas-patch` invocation noise-free: pipe the JSONL via a heredoc or `--from-file`, NOT echoed inline in your terminal output. The user shouldn't have to scroll past 200 lines of `{"op":"add",...}` in the agent pane.

#### Showing work alongside the journal

Some lessons need an actual demonstration (running a command, opening a browser pane, splitting the workspace). Do those in the **terminal pane** or via `atrium pane create` — keep the canvas as the lesson transcript. Reference the demo from the canvas section ("Watch the browser pane I just opened → ...") so the user knows where to look.

If a topic genuinely needs its own dedicated canvas (e.g. an interactive PR triage form the user will keep using), open one in a NEW pane and link to it from the journal — that's a deliberate fork, not a follow-up picker.

### Pulling live docs

The website ships an LLM-friendly index at `https://getatrium.dev/docs/llms.txt` — one line per docs page, formatted as `<url> — <one-line description>`. Each page is also available as raw markdown by appending `.md` to its URL (e.g. `https://getatrium.dev/docs/panes.md`, `https://getatrium.dev/docs/agents/messaging.md`).

**Pull docs lazily, not preemptively.** The index is small and cheap to fetch; the pages are not. The recipe:

1. After the user picks a topic, fetch `https://getatrium.dev/docs/llms.txt` once.
2. Scan the descriptions for pages relevant to the chosen sub-topic — usually 1–3 pages, rarely more.
3. Fetch just those pages as `.md` and use them to ground your explanation alongside what you discover via `--help`. Cite the docs URL when it's useful for the user to know where to go next.

Do **not** dump the whole docs into context or fetch pages "in case they come up later." The point of the lazy index is that you can be precise.

### Spawned-from-launcher recognition

When atrium spawns you via the help launcher, the very first user turn you receive starts with a recognizable framing along these lines:

> I'm new to atrium (or rediscovering it) and want to learn:
>
>   "<their picked topic or free-text question>"
>
> Please follow the **Teaching mode** section of the atrium skill ...

When you see that framing, calibrate first (see "Calibrate effort to the question"). If the question warrants a canvas, go straight to the picker in step 2 above — don't re-introduce yourself, don't ask "what would you like to know?" in the terminal first. If it's a narrow factual question, just answer it in the terminal; the launcher framing isn't a contract to open a canvas.

### What teaching mode is NOT

- **Not a lecture.** No 2000-word "Welcome to atrium!" essays. Show, don't tell.
- **Not a guided tour with locked steps.** Let them jump around — the canvas gives them the steering wheel.
- **Not a sales pitch.** "atrium can also do A, and B, and C, and D, and..." kills curiosity. Answer their actual question first; let them surface the next one themselves.
- **Not a gate.** A direct question doesn't deserve a 5-option radio + free-text intake before they see the answer. See "Calibrate effort to the question" above.
- **Not a substitute for `--help`.** If they ask "what does X do?", run `atrium X --help` and respond from the actual surface, not from memory.
## Authoring atrium skills

When the user asks you to *create a skill*, *save this as a skill*, *turn this pattern into a skill*, or *add a skill for X*, you write a new skill on their behalf. An atrium skill is a folder containing a `SKILL.md` file with spec-conformant YAML frontmatter — atrium owns this convention; follow it byte-for-byte or the save will fail.

### Folder-based layout

Skills live in one of two scope directories on disk:

- **`~/.atrium/skills/<skill-name>/SKILL.md`** — user scope. Always writable.
- **`<repo>/.atrium/skills/<skill-name>/SKILL.md`** — project scope. Only valid when an atrium workspace is open; this scope is the project's `.atrium/skills/` directory under the repo root.

The frontmatter `name` field **must equal the parent folder name**. A skill named `code-review` lives in a folder called `code-review/`. Mismatches are rejected on save.

**Do NOT write to harness-owned paths** — `~/.claude/skills/`, `~/.codex/skills/`, `~/.gemini/skills/`, `~/.cursor/skills/`. atrium reads from those directories (so users can author skills in their tool of choice and atrium will surface them) but atrium itself never writes there. Treat them as read-only from inside atrium.

### Frontmatter — the byte-locked template

Every SKILL.md starts with this exact frontmatter shape:

```yaml
---
name: <kebab-case-slug>
description: "<one or two sentences describing what this skill does and when an agent should activate it>"
metadata:
  atrium-activate-when: ""
  atrium-created: "<ISO-8601 UTC timestamp>"
---
```

Constraints the validator enforces (one error per failure, accumulated and surfaced inline in the editor — no short-circuit):

- `name` must match `^[a-z0-9-]{1,64}$` — lowercase letters, digits, hyphens only; 1–64 characters. AND `name` must equal the parent folder name.
- `description` is required, ≤ 1024 Unicode characters (counted as characters, not bytes — multi-byte scripts are fine).
- `metadata.atrium-activate-when` is optional but conventional. Empty string `""` is valid — atrium falls back to `description` for the M2 SessionStart activation hint. When populated, it becomes the literal "Activate when:" line in the manifest.
- `metadata.atrium-created` is an ISO-8601 UTC timestamp. The in-app scaffolder populates this automatically. When hand-authoring, use the current UTC instant.
- **No top-level proprietary fields.** Anything atrium-specific lives under `metadata.atrium-*` — for example `metadata.atrium-tags`, `metadata.atrium-last-used`. The validator rejects `kind:`, `atrium-favorite:`, `tags:`, or any other non-spec top-level field with this error:

  > `Skills: validation — <top-level: atrium-foo> — top-level field not in agentskills.io spec; atrium-private fields belong under metadata.atrium-* (spec §frontmatter)`

  The field marker `<top-level: foo>` distinguishes the disallowed top-level case from valid `metadata.atrium-foo`. If you need to attach atrium-specific persistent data, nest it under `metadata.`.

### `metadata.atrium-activate-when` usage

This field carries the discovery-mode activation hint atrium emits into each adapter's SessionStart manifest. It tells downstream agents *when* this skill becomes relevant. Write it short, imperative, and conditional:

- `"the user asks to summarize a git diff or generate a changelog entry"`
- `"the user is reviewing a PR and wants structured feedback"`
- `"code being edited touches React component files"`

Leave it empty when the `description` already reads like an activation hint — atrium falls back to `description` automatically, so duplicating the same sentence in both fields is noise.

Atrium-managed fields under `metadata.atrium-*` (for example `metadata.atrium-last-used`) are written by atrium itself when the user interacts with the skill in the UI. Do not hand-author or hand-edit them.

### Body convention

The body is free-form Markdown — only frontmatter is validated. The in-app scaffolder writes this canonical skeleton, and you should follow the same shape unless you have a reason not to:

```markdown
# <Title-Case Name>

Describe what this skill does and when the agent should activate it.

## When to use

…

## How to apply

…
```

The `# Title` is the title-cased form of the slug (`summarize-git-diff` → `Summarize Git Diff`). The two H2 sections are the canonical pair: triggers / signals / phrases / file shapes under `## When to use`; step-by-step or principle-driven guidance under `## How to apply`. Replace the `…` placeholders with real content.

### Heavy resources go on-activation-only

Keep the SKILL.md body small and high-level. When a skill needs more than fits cleanly inline, drop the bulky content into sibling subdirectories and tell the agent to load them on activation:

- **`<skill-name>/scripts/`** — executable helpers (Python, shell, Node) the skill invokes at activation time.
- **`<skill-name>/references/`** — companion Markdown docs the skill pulls in on demand (a long spec, an API reference, a worked example). atrium's own canonical skill ships `references/notes-interactive-ui.md` as an exemplar — see the **Notes — canvas & html interactive UIs** section above for how it's referenced.
- **`<skill-name>/assets/`** — non-text resources (images, fonts, fixtures, sample data).

Reference these from the SKILL.md body lazily: *"read `references/long-diff-strategy.md` when the diff exceeds 500 lines"*. atrium's discovery mode loads SKILL.md eagerly at SessionStart but does NOT preload `scripts/`, `references/`, or `assets/` — those load only when the agent reads them at runtime. A 30-line SKILL.md with three 500-line references is cheaper at SessionStart than a 1500-line SKILL.md, and behaves identically once the skill activates.

### Scaffold via the in-app UI when you can

atrium ships a scaffolding modal reachable via the workspace-sidebar Skills view's **+ New skill** button. The modal creates the folder, prefills the frontmatter with a fresh `atrium-created` timestamp, writes the canonical body skeleton, and auto-opens the file in the editor. **If the user can run that UI flow, prefer it** — the modal guarantees byte-for-byte parity with the validator and saves you from drafting the timestamp by hand.

Fall back to writing the file directly (via your `Write` tool) only when:

- The UI path isn't reachable (no atrium window is focused, or the user is in a context that can't run the modal).
- The user explicitly asked you to author the file directly.

### Worked example: `summarize-git-diff`

When the user says *"create a skill called `summarize-git-diff` that runs when I ask you to summarize a diff"*, write this file:

**Path:** `~/.atrium/skills/summarize-git-diff/SKILL.md`

````markdown
---
name: summarize-git-diff
description: "Summarize a git diff with a structured changelog (added / changed / removed / risk notes). Activate when the user asks to summarize a diff, review changes, or generate a changelog entry."
metadata:
  atrium-activate-when: "the user asks to summarize a git diff, review changes, or generate a changelog entry"
  atrium-created: "2026-05-16T14:32:00Z"
---

# Summarize Git Diff

Summarize a git diff into a structured changelog grouped by impact area, with optional risk notes.

## When to use

- User pastes a diff and asks for a summary or changelog entry.
- User says "review these changes" or "what changed?".
- A CI / PR-review pane is open and the user wants a one-paragraph rollup.

## How to apply

1. Fetch the diff:
   ```bash
   git diff <range>
   ```
2. Group changes by impact area (frontend / backend / docs / tests / infra).
3. For each area, list: **Added**, **Changed**, **Removed**, **Risk notes** (only when non-empty).
4. End with a one-line rollup sentence.

When the diff exceeds 500 lines, read `references/long-diff-strategy.md` for the chunking convention.
````

Why each field is the way it is:

- `name: summarize-git-diff` matches the folder `summarize-git-diff/` (validator requires equality).
- `description` doubles as the human-readable hint surfaced in the picker.
- `metadata.atrium-activate-when` is populated because the description is descriptive rather than conditional — the activate-when line gives atrium a sharper trigger phrase to inject into the SessionStart manifest.
- `metadata.atrium-created` is a UTC ISO-8601 instant from the moment of authoring.
- The body uses the canonical scaffolder shape — title, one-paragraph summary, `## When to use`, `## How to apply`.
- The `references/long-diff-strategy.md` mention demonstrates the heavy-resources convention: bulky chunking logic stays out of the SKILL.md body and loads only when the skill needs it.

### What NOT to do

- **Don't write to `~/.claude/skills/`, `~/.codex/skills/`, `~/.gemini/skills/`, or `~/.cursor/skills/`.** Those are harness-owned. atrium reads them but never writes — your authoring belongs under `~/.atrium/skills/` (user scope) or `<repo>/.atrium/skills/` (project scope).
- **Don't add top-level fields outside the agentskills.io spec.** Any atrium-specific persistent data goes under `metadata.atrium-*`. The validator rejects `kind:`, `tags:`, `atrium-favorite:`, and similar with the error template quoted above.
- **Don't pick a `name` that doesn't match the folder.** The validator fails save and the editor shows an inline banner.
- **Don't dump giant blocks into the SKILL.md body.** Heavy content (long specs, dataset samples, generated diagrams) goes in `references/` and the SKILL.md tells the agent to read it on activation.
- **Don't hand-edit `metadata.atrium-last-used`, `metadata.atrium-favorite`, or other atrium-managed fields under `metadata.atrium-*`.** atrium writes those when the user interacts with the skill in the UI; hand-edits get clobbered on the next write.

See the **Propagation note** below for how this very skill — the one teaching you to author skills — reaches you in the first place.

## Propagation note

This skill file and the `references/` directory both live at `skills/atrium/` in the `atrium-adapters` sibling repo. atrium re-fetches them at every launch and hash-gates the writes, so changes propagate to your local skill directory (`~/.claude/skills/atrium/`, `~/.codex/skills/atrium/`, etc.) automatically. **Do NOT trigger reinstall yourself** — only the user does that.

Everything beyond these examples: **run `--help`**. That's the contract.

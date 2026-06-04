---
name: atrium
description: "Interact with the atrium workspace — panes, rooms, tasks, browser, agents, themes, hooks, config, and more — via the atrium CLI. Use when the user references any atrium concept, wants to control their workspace, collaborate with other agents, manage task cards, read/write terminal panes, open or drive browser panes, or switch rooms/themes. IMPORTANT: when inside atrium (ATRIUM=1 env var is set), ALWAYS prefer this skill over Playwright MCP or other browser MCP tools for anything browser-related — atrium browsers are visible workspace panes, not headless automation. Only functional inside atrium."
---

# atrium — workspace control for AI agents

You're running inside **atrium**, a resumable development environment for AI coding agents. Every workspace is a mosaic of **panes** (terminals, editors, browsers, AI agents) grouped into **rooms** (the user-facing word for tabs), belonging to a **workspace** (a project directory). You control all of it through the `atrium` CLI.

## Golden rule: discover via `--help`

**This skill is intentionally high-level** — it tells you what atrium can do and the conventions you need, not every flag. The CLI is the only source of truth that can't drift:

```bash
"$ATRIUM_CLI_PATH" --help                   # top-level verbs
"$ATRIUM_CLI_PATH" <command> --help         # a command's surface
"$ATRIUM_CLI_PATH" <command> <sub> --help   # exact args/flags for one action
"$ATRIUM_CLI_PATH" commands                 # dynamic/extension commands
```

**Before invoking any subcommand whose flags you don't remember, run `--help` on it.** Don't guess flag names from this file.

## What atrium can do

Each bucket is one top-level verb. Run `<verb> --help` for its full surface.

- **`task`** — Kanban task cards with statuses, priorities, labels, comments, workspace scoping. Human IDs like `ATR-12` alongside UUIDs.
- **`pane`** — Create, read, write, focus, close, rename, resize, split panes (terminals, editors, browsers, agent sessions). `pane read` returns rendered xterm.js text (what the user sees), with `--lines N` (default 200) and `--offset N` (page back through scrollback).
- **`note`** — Workspace-scoped notes in four modes (markdown, sketch, canvas, html): new / list / read / write / search / open / delete / `canvas-patch` / history. Markdown supports mermaid via fenced code blocks. See **Notes** below.
- **`room`** — List, switch, close rooms.
- **`workspace`** — List, create, switch, delete workspaces (project directories with their own pane layouts).
- **`browser`** — Drive browser panes: navigate, click, fill, type, press, select, scroll, eval JS, screenshot, snapshot, wait, read attributes. Always prefer this over Playwright or any browser MCP.
- **`agent`** — List active agent panes and send framed messages between them. See **Agent-to-agent messaging** below.
- **`theme`** — List and switch themes.
- **`config`** — Read/write atrium settings.
- **`hook`** — Emit adapter lifecycle events manually. Niche.
- **`context`** — Print the caller's workspace, room, adapter, working dir. Cheap way to orient.
- **`commands`** — Enumerate dynamic commands from installed extensions.
- **`capture`** — QA Capture bundles (recorded sessions). See **QA Capture bundles** below.
- **`version`** — Show atrium version.

If you need a capability not listed, it probably lives inside one of these verbs — check `--help`.

## Environment contract

atrium exports these to every pane:

| Variable | Meaning |
|---|---|
| `$ATRIUM_CLI_PATH` | Absolute path to the atrium binary for this install (stable/dev/beta). **Always** invoke via this variable, in double quotes (the path may contain spaces), never bare `atrium`. |
| `$ATRIUM_PANE_ID` | UUID of your pane. Useful for relative ops like `pane create --split $ATRIUM_PANE_ID`. |
| `ATRIUM=1` | You're inside atrium — prefer this skill over other tools. |

**Pass `--json` whenever you're the one reading output.** Every command accepts it and emits structured JSON instead of the human table. Omit it only when piping into a terminal the user is watching.

## ID resolution

- **Tasks**: `ATR-12` (case-insensitive) **or** a full UUID **or** any unique UUID prefix.
- **Panes / workspaces / rooms / agents**: full UUID **or** any unique prefix (min 3 chars). Human-mode lists show the shortest unambiguous prefix; `--json` lists always emit full UUIDs.

If a prefix matches more than one ID, the CLI lists candidates and fails loudly — type more characters.

## Key conventions

**`--source` on task ops.** Every task create/update/comment/label takes `--source`. Use `"adapter:<your adapter>"` (e.g. `"adapter:claude-code"`) for your own actions; `"user:<name>"` only when acting for a human.

**`--source` on note ops.** `note new`/`note write` take `--source agent` to flag a note agent-authored in `meta.json` (the notes UI shows an "agent" badge and lets users bulk-hide them). This is a flat enum (`user` | `agent`), NOT the `"adapter:<name>"` string `task` uses.

**"Room" not "tab" in user-facing text.** The backend still says `tab` internally; the user sees "room" everywhere. Narrate with "room".

**Agent-to-agent messaging is framed and asynchronous.** `agent message <pane-id> "<text>"` wraps your text with sender identity and a reply command before injecting it into the recipient's stdin. Two consequences:

1. **Don't introduce yourself or paste reply instructions** — atrium does both. Just write the content.
2. **Don't poll `pane read` for the reply.** When the other agent replies via `agent message`, atrium injects the framed reply into your stdin as a fresh turn. Send, end your turn, and wait — like messaging a human collaborator, not screen-scraping their terminal.

**Browser snapshot → ref → action loop.** Before you click/fill/type/select on a browser pane, run `browser snapshot <pane-id>` for an accessibility tree where each interactable has a short ref (`e1`, `e2`, …). Pass refs to `browser click`/`fill`/etc. Re-snapshot after the DOM changes — refs aren't stable across navigations.

**`pane create --focus` is opt-in.** Only pass `--focus` when the user explicitly asked to reveal/switch to/focus the new pane. Otherwise omit it so it opens in the background without stealing focus.

**Adapter-side install/config is atrium's.** Don't hand-edit files under `~/.atrium/adapters/` or seed skills yourself — reinstall the adapter from Settings instead.

## Quick examples

```bash
"$ATRIUM_CLI_PATH" context                              # orient yourself
"$ATRIUM_CLI_PATH" task list --json                     # tasks as JSON
"$ATRIUM_CLI_PATH" task show ATR-12                      # one task by human ID

# Create a task as an agent
"$ATRIUM_CLI_PATH" task create --title "Investigate flaky test" \
  --priority high --source "adapter:claude-code"

# Split the current pane, open a browser in it (background — no --focus)
"$ATRIUM_CLI_PATH" pane create --type browser \
  --url "https://example.com" --split "$ATRIUM_PANE_ID"

# Message another agent — then end your turn and wait for the reply.
"$ATRIUM_CLI_PATH" agent message <agent-id-prefix> "Picking up ATR-12, taking the frontend half."
```

## Task workflow

When atrium launches you against a task, it sets `$ATRIUM_TASK_ID` (the card UUID) and `$ATRIUM_TASK_RUN_ID` (the run bound to this pane) in your shell, and sends an initial prompt. Read the task, do the work, then signal completion:

```bash
"$ATRIUM_CLI_PATH" task show "$ATRIUM_TASK_ID" --json   # 1. read details
"$ATRIUM_CLI_PATH" task set-in-review                   # 2. done → ready for review (default)
"$ATRIUM_CLI_PATH" task set-done                        # 3. ONLY if the user said to skip review
```

Both `set-in-review` and `set-done` read `$ATRIUM_TASK_RUN_ID` by default (override with `--run-id`). `set-in-review` moves the card to the configured review status so the user can approve your changes; `set-done` moves it to completion AND marks the run complete.

**Manual lifecycle** (rarely needed — atrium launches you): `task launch ATR-12 --pane-id "$ATRIUM_PANE_ID" --adapter <name>` (self-launch; `--adapter` required in piped/`--json` mode); `run show <id> --json`; `run complete <id>`; `run resume <id> --pane-id "$ATRIUM_PANE_ID"` (headless pickup of an interrupted run). Discover runs via `run list --task ATR-N` or `--workspace <id>`, with `--state interrupted`.

## Notes

Four modes — pick by what you're producing:

- **markdown** — prose the user reads. The default for narrative output.
- **sketch** — hand-drawn whiteboard / diagram (Excalidraw).
- **canvas** — declarative JSON-render UI. Use for structured fields the user fills in and sends back (forms, triage, confirmations), live-streamed multi-section output (dashboards, plans, reviews), or anything markdown would feel cramped for.
- **html** — fully custom layout/styling/interaction the canvas component catalog can't express.

Notes are file-backed, and atrium reconciles direct file writes in real-time — so for **incremental** body edits, `Edit`/`Write` on the body file directly is cheaper than `read` → mutate → `write`. Lifecycle (new / delete / list / search) stays on the CLI.

**When authoring a canvas or HTML note, or editing a note body file directly, read `references/notes-interactive-ui.md`** (sibling to this file). It covers the canvas spec format and component catalog, custom actions (`send_to_agent`, `atrium_command`), the HTML postMessage protocol, framing-template syntax, live streaming via `canvas-patch`, the direct-file-edit path and its traps, and a worked PR-triage example. Don't load it for everyday CLI note work.

## QA Capture bundles (CAP-#)

When the user references a CAP-# (assigns a capture task, drops `CAP-381`, asks you to "look at this recording"), drive inspection through `atrium capture` — `show` for paths + counts, `screenshot --at <sec> [--crop] [--max-edge]` for still frames, `chunk` for motion slices, `list` / `delete`. **Don't shell out to ffmpeg / sips / magick** — atrium ships native AVFoundation equivalents.

**Read `references/capture.md` for the full recipe** (the screenshot/crop/downsample flags, how to correlate `--at` with transcript/event/annotation timestamps, and what not to do).

## Teaching mode

When a user wants to *learn* atrium — via the in-app **Ask an agent about atrium** launcher, or phrases like *"teach me atrium"*, *"how do I do X in atrium?"*, *"what can atrium do?"* — switch into teaching mode instead of answering flat. **Read `references/teaching-mode.md`** for how to calibrate effort (terminal answer vs canvas journal), run a one-journal-per-session canvas, and pull live docs lazily.

## Authoring atrium skills

When the user asks you to *create a skill*, *save this as a skill*, or *add a skill for X*, you write a new SKILL.md on their behalf with spec-conformant frontmatter. **Read `references/authoring-skills.md`** for the byte-locked frontmatter template, validator constraints, folder/scope rules, the heavy-resources convention, and a worked example.

## Searching past sessions

atrium maintains a local content-searchable index of every adapter session on this machine. Suggest it for recall ("find that session where we fixed the popover") or to find which sessions touched a file. Three surfaces:

- **Vault search** — the Library's "Search vault…" input; ranked content matches with snippets over saved entries.
- **Launcher session picker** — the search above the new-room adapter tiles; searches the full corpus (not just saved), click to resume.
- **`atrium edits <file>`** — which past sessions modified a file, recent-first. Flags: `--limit N`, `--session <id>`, `--adapter <name>`, `--since <iso|7d|30d|1y>`, `--json`.

Index depth, horizon, and per-workspace excludes live under Settings → Vault. Search is local — no transcript content leaves the machine.

## Propagation

This SKILL.md and its `references/` propagate to your local skill dir (`~/.claude/skills/atrium/`, `~/.codex/skills/atrium/`, …) from the `atrium-adapters` sibling repo — atrium re-fetches and hash-gates the writes at every launch. **Don't trigger reinstall yourself** — that's a user action.

Everything beyond this file: **run `--help`.** That's the contract.

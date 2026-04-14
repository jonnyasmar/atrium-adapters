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

Everything beyond these examples: **run `--help`**. That's the contract.

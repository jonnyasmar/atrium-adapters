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
- **`note`** — Create, list, read, write, search, open, delete, and view history of workspace-scoped notes across five modes (markdown, sketch, mermaid, canvas, html). Notes live on disk under `~/.atrium/notes/<workspaceId>/<noteId>/`; agent-authored notes carry `--source agent` so users can hide or filter them. SVG/PNG export available for sketch notes when the desktop app is running. See the **Notes — canvas & html interactive UIs** section below for the agent-authoring vocabulary for canvas/html (interactive UIs the user can fill in and send back).
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

## Notes — canvas & html interactive UIs

atrium notes have five modes. Three (markdown, sketch, mermaid) are agent-readable content. Two (**canvas**, **html**) are **interactive UIs the user fills in and sends back to you**. Use canvas/html when you need the user to:

- Triage a list (e.g. 40 PRs with a priority dropdown + notes field per row).
- Confirm a destructive operation with structured input (e.g. select which files to delete).
- Provide multi-field structured feedback (e.g. a bug-report form).
- Anything where a wall of text + numbered list in the terminal would be high cognitive load.

The bidirectional model:

1. You author a UI (JSON spec for canvas, raw HTML for html) and ship it via `atrium note new`.
2. atrium auto-opens a notepad pane in the user's current room showing the UI (when you pass `--open`).
3. The user interacts (fills fields, clicks buttons).
4. The user clicks "Send to agent" (or your UI's own send button) — atrium applies the framing template and injects the result into your stdin as a fresh user turn.

### Choosing canvas vs html

- **canvas** — declarative JSON spec rendered by `@json-render/react`. Safer (no agent-authored JS; components are predefined), more structured, and the user's form state lives in the renderer's state model (note-scoped). Use this for **everything except cases where the curated component set can't express what you need**.
- **html** — agent-authored HTML in a sandboxed iframe (`sandbox="allow-scripts"`). Use when the canvas component set can't express your layout / interaction (custom CSS, agent-authored JS-driven flows). Stateless across pane reloads in v1 — the iframe has an opaque sandbox origin, so `localStorage` is isolated and there is no persistence layer behind the iframe yet.

### CLI invocation

Always read `--help` first; the implementation is the source of truth for flag names:

```bash
"$ATRIUM_CLI_PATH" note new --help
```

Canvas creation (spec from stdin, the canonical pattern):

```bash
cat <<'EOF' | "$ATRIUM_CLI_PATH" note new \
  --type canvas \
  --title "PR triage" \
  --send-framing "User triage result for stale PRs:\n\n{payload}" \
  --source agent \
  --open \
  --spec - \
  --json
{
  "root": "rootCard",
  "elements": {
    "rootCard": {
      "type": "Card",
      "props": {"title": "Triage stale PRs"},
      "children": ["form"]
    },
    "form": {
      "type": "Stack",
      "props": {"direction": "column", "gap": 16},
      "children": ["priorityLabel", "prioritySelect", "noteLabel", "noteInput", "submitBtn"]
    },
    "priorityLabel": {"type": "Label", "props": {"text": "Priority"}, "children": []},
    "prioritySelect": {
      "type": "Select",
      "props": {
        "value": {"$bindState": "/priority"},
        "options": [
          {"value": "high",   "label": "High"},
          {"value": "medium", "label": "Medium"},
          {"value": "low",    "label": "Low"}
        ]
      },
      "children": []
    },
    "noteLabel": {"type": "Label", "props": {"text": "Notes"}, "children": []},
    "noteInput": {
      "type": "Textarea",
      "props": {"value": {"$bindState": "/note"}, "rows": 4},
      "children": []
    },
    "submitBtn": {
      "type": "Button",
      "props": {"label": "Send", "variant": "primary"},
      "children": [],
      "on": {
        "press": {
          "action": "send_to_agent",
          "params": {"payload": {"$state": ""}}
        }
      }
    }
  }
}
EOF
# Output (with --json): {"meta": {...}, "paneId": "<pane-uuid-or-null>"}
```

HTML creation (body from a file):

```bash
"$ATRIUM_CLI_PATH" note new \
  --type html \
  --title "Confirm file deletion" \
  --send-framing "User decision:\n\n{payload}" \
  --source agent \
  --open \
  --body ./confirmation.html \
  --json
```

Flag notes:

- `--type {markdown|sketch|mermaid|canvas|html}`. For `canvas` you MUST pass `--spec`; for `html` you MUST pass `--body`. The two are mutually exclusive (clap-enforced) and rejected for the other three types.
- `--spec` / `--body` accept either a file path or `-` (read piped stdin). Refusing TTY stdin is intentional — it avoids the "agent froze waiting for input" footgun.
- `--send-framing "<template>"` stores the framing in `meta.json` as `sendFraming`. The Send-to-agent chrome reads it back. Variables: `{payload}`, `{noteId}`, `{noteTitle}`, `{actionId}` — see **Framing template syntax** below.
- `--open` is opt-in (default false). For canvas/html you almost always want it — without `--open` the note is durable on disk but no pane is opened.
- `--source agent` flags the note as agent-authored in `meta.json` so the user can filter or hide agent notes in bulk. Use it whenever you author a note autonomously.
- The CLI captures `$ATRIUM_PANE_ID` from your environment and stores it as `meta.originAgentPaneId`, so the Send-to-agent chrome defaults its target dropdown to "your pane".
- Pass `--json` on every invocation; you are an agent parsing output.

### Canvas spec format

A canvas spec is a single JSON object stored as the note body in `note.canvas.json`. Top-level shape (from `@json-render/core`'s `Spec` type):

```json
{
  "root": "<elementKey>",
  "elements": {
    "<elementKey>": {
      "type": "<ComponentName>",
      "props": { /* ... */ },
      "children": ["<elementKey>", "..."],
      "on": {
        "<eventName>": {"action": "<actionName>", "params": { /* ... */ }}
      },
      "visible": "<optional condition>",
      "repeat": {"statePath": "/items", "key": "id"}
    }
  },
  "state": { /* optional initial state */ }
}
```

- `root` — the key of the root element in the `elements` map.
- `elements` — a flat map of element key → element. Each element has `type` (one of the components below), `props` (the component's prop shape), optional `children` (an array of element keys), and optional `on` event bindings.
- `state` — optional object that seeds the renderer's state model.
- **`repeat`**: render children once per item in a state array. Inside repeated children, use `{"$item": "field"}` to read a field of the current item, `{"$index": true}` for the index, and `{"$bindItem": "field"}` for two-way binding to an item field.

#### Reading state — two different directives

json-render has TWO state-access directives. Mixing them up is the #1 source of "my button doesn't do anything" bugs:

- **`{"$bindState": "/jsonPointer"}`** — **render-time, two-way binding** for input PROPS. Read AND write the JSON Pointer path. Use ONLY on prop values that interact with form-control state — `value` on Input/Textarea/Select/Slider/Radio, `checked` on Checkbox/Switch, `pressed` on Toggle, `value` on ToggleGroup/Tabs, etc.

  ```json
  { "type": "Input", "props": { "value": { "$bindState": "/email" } } }
  ```

- **`{"$state": "/jsonPointer"}`** — **action-time, read-only** for action params. Resolved when the action fires; reads the JSON Pointer path from the current state. Use empty string `""` to read the whole state.

  ```json
  { "on": { "press": { "action": "send_to_agent", "params": {
    "payload": { "$state": "" }
  }}}}
  ```

**Wrong** (silent no-op — `$bindState` is render-only, action params won't resolve it):

```json
"params": { "payload": { "$bindState": "$state" } }
```

**Right** (action params use `$state`):

```json
"params": { "payload": { "$state": "" } }         // whole state
"params": { "payload": { "$state": "/multiline" } } // single field
```

atrium hardens the `send_to_agent` handler against this mistake — if `params.payload` doesn't resolve, the handler falls back to the live canvas state. But other actions (or third-party handlers) won't have that safety net.

### The component catalog

atrium implements the **full json-render standard catalog** — all 41 components from json-render.dev plus `Label` (atrium-specific for a11y pairing). Most components map to a corresponding atrium primitive (`Button` wraps `ui/button`, `Switch` wraps `ui/switch`, `Checkbox` wraps `shared/Checkbox`, `Dialog` wraps `ui/dialog`, `DropdownMenu` wraps `ui/dropdown-menu`) so they inherit any future styling updates automatically.

**Layout & display:**

| Component | Key props |
|---|---|
| `Stack`     | `direction?: "row"\|"column"`, `gap?: number` |
| `Grid`      | `columns?: 1..6`, `gap?: number` |
| `Card`      | `title?: string`, `description?: string` |
| `Carousel`  | `items: { title?, content? }[]` (scroll-snap row) |
| `Separator` | `orientation?: "horizontal"\|"vertical"` |
| `Heading`   | `text: string`, `level?: 1..6` |
| `Text`      | `content: string`, `tone?: "default"\|"muted"\|"destructive"\|"success"\|"warning"` |
| `Label`     | `text: string`, `htmlFor?: string` |
| `Icon`      | `name: string` (Lucide), `size?: number`, `color?: string` |
| `Image`     | `src?: string`, `alt?: string`, `width?`, `height?` |

**Form inputs (all bind via `useBoundProp`):**

| Component | Key props |
|---|---|
| `Input`       | `value?` (bind), `label?`, `placeholder?`, `type?: "text"\|"email"\|"url"\|"number"\|"password"` |
| `Textarea`    | `value?` (bind), `label?`, `placeholder?`, `rows?: number` |
| `Select`      | `value?` (bind), `label?`, `placeholder?`, `options: { value, label }[]` |
| `Checkbox`    | `checked?` (bind), `label?`, `disabled?` |
| `Radio`       | `value?` (bind), `label?`, `options: { value, label }[]` |
| `Switch`      | `checked?` (bind), `label?`, `disabled?` |
| `Slider`      | `value?` (bind), `label?`, `min?`, `max?`, `step?` |
| `Toggle`      | `pressed?` (bind), `label: string`, `variant?: "default"\|"outline"` |
| `ToggleGroup` | `value?` (bind), `type?: "single"\|"multiple"`, `items: { value, label }[]` |

**Interactive & disclosure:**

| Component | Key props |
|---|---|
| `Button`       | `label: string`, `variant?: "default"\|"primary"\|"secondary"\|"destructive"\|"ghost"\|"outline"\|"link"`, `disabled?`. Fires `press`. |
| `ButtonGroup`  | `buttons: { value, label, variant? }[]`, `selected?` (bind). Fires `change`. |
| `Link`         | `label: string`, `href?: string`. Fires `press`. |
| `DropdownMenu` | `label: string`, `items: { value, label }[]`. Fires `select`. |
| `Popover`      | `trigger: string`, `content: string` |
| `Dialog`       | `title?`, `description?`, `openPath: string` (state path to a boolean) |
| `Drawer`       | `title?`, `description?`, `openPath: string` (bottom sheet) |
| `Tabs`         | `tabs: { value, label }[]`, `value?` (bind), `defaultValue?`. Children render as panels in tab order. |
| `Accordion`    | `items: { value, title }[]`, `type?: "single"\|"multiple"`. Children render as panels in item order. |
| `Collapsible`  | `title: string`, `defaultOpen?: boolean` |
| `Tooltip`      | `text: string` (trigger), `content: string` (hover) |

**Feedback & data display:**

| Component | Key props |
|---|---|
| `Alert`      | `message: string`, `title?`, `type?: "info"\|"success"\|"warning"\|"destructive"` |
| `Badge`      | `text: string`, `variant?: "default"\|"success"\|"warning"\|"destructive"\|"muted"` |
| `Spinner`    | `size?: number`, `label?: string` |
| `Skeleton`   | `width?`, `height?`, `rounded?: boolean` |
| `Avatar`     | `src?`, `name?` (initials fallback), `size?: number` |
| `Progress`   | `value: number`, `max?: number`, `label?: string` |
| `Metric`     | `label: string`, `value: string\|number`, `change?`, `changeType?: "positive"\|"negative"\|"neutral"`, `prefix?`, `suffix?` |
| `Rating`     | `value?` (bind), `max?: number`, `label?`, `interactive?: boolean` |
| `Table`      | `columns: { key, label, align? }[]`, `rows: Record<string, unknown>[]`, `caption?` |
| `Pagination` | `totalPages: number`, `page?` (bind, 1-indexed). Fires `change`. |
| `BarGraph`   | `title?: string`, `data: { name, ...numericSeries }[]` |
| `LineGraph`  | `title?: string`, `data: { name, ...numericSeries }[]` |

For json-render conventions (visibility conditions, repeat, action bindings), see the catalog's upstream docs at https://json-render.dev — atrium implements the same vocabulary. Renderers use atrium tokens (`var(--accent)`, `var(--surface)`, `scaledPx()`, etc.) so canvas notes match the rest of atrium's chrome and pick up theme changes automatically.

### Custom actions (atrium-specific)

Two custom actions extend the catalog beyond the standard json-render set:

- **`send_to_agent`** — send the current state (or a custom payload) back to an agent.

  ```json
  {"action": "send_to_agent", "params": {
    "payload": {"$state": ""},
    "framing": "Optional override of the note's sendFraming",
    "target": "Optional pane id; default is originAgentPaneId"
  }}
  ```

  **Action params use `{"$state": "<jsonPointer>"}` to read state — NOT `{"$bindState": ...}` (which is render-only).** See the State binding subsection above.

  All three params are optional. Fallback chain:
  - `payload` omitted → the current canvas state is sent.
  - `framing` omitted → the note's `meta.sendFraming` is used (set via `--send-framing` at create time); falling back to `"{payload}"` if neither is set.
  - `target` omitted → `meta.originAgentPaneId` (the agent that created the note) is the destination. If neither `target` nor `originAgentPaneId` is set, the bridge throws — 52.5's Send-to-agent chrome supplies the target via its dropdown, so this only fires for spec-only invocations that lose both fallbacks.

- **`atrium_command`** — invoke an `atrium://` protocol URI to drive any atrium command surface from the canvas.

  ```json
  {"action": "atrium_command", "params": {"uri": "atrium://..."}}
  ```

  The `uri` is required and MUST start with `atrium://` (Zod-refined; malformed URIs throw at action-fire time and surface a toast in the canvas). Failures show a `toast.error` on the canvas surface; successes are silent (most commands have a visible side effect).

  **Available commands** (use ONLY these — guessing a URI that isn't registered will toast a "Command failed" error):

  | URI | Params | Effect |
  |---|---|---|
  | `atrium://commands/workspace.create` | `name?: string` | Create a new workspace |
  | `atrium://commands/workspace.delete` | `workspaceId: string` | Delete a workspace |
  | `atrium://commands/theme.switch` | — | Cycle through atrium themes |
  | `atrium://commands/config.set` | `key, value` | Update a config setting |
  | `atrium://commands/pane.create` | `workspaceId, type, position?` | Open a new pane (`type` ∈ `"terminal" \| "browser" \| ...`) |
  | `atrium://commands/pane.close` | `paneId` | Close a pane |
  | `atrium://commands/pane.resize` | `paneId, direction` | Resize a pane |
  | `atrium://commands/pane.split` | `paneId, type, direction` | Split a pane |
  | `atrium://commands/pane.rename` | `paneId, name` | Rename a pane |
  | `atrium://commands/notepad.open` | `noteId, workspaceId` | Open a specific note in a notepad pane |
  | `atrium://commands/file.open` | `path` (or `filePath`), `workspaceId?` | Open a file in an editor pane |
  | `atrium://commands/adapter.list` | — | List installed adapters (read-only) |

  Params are passed in `params.params` (yes, the binding's `params` field carries the command's params object — atrium unwraps it):

  ```json
  {"action": "atrium_command", "params": {
    "uri": "atrium://commands/notepad.open",
    "noteId": "019e1d…",
    "workspaceId": "25b5cba7-…"
  }}
  ```

  (Note: there is NO `notes.open` or "open the notes finder" command today. To create a note from a canvas action, use `pane.create` with the appropriate type or wire `send_to_agent` with a "please create a note" instruction.)

### HTML postMessage protocol

When you author HTML, the iframe runs in `sandbox="allow-scripts"` only — no `allow-same-origin`, no `allow-forms`, no `allow-popups`, no `allow-modals`. Implications: no DOM access to the parent, no cookies, no credentialed fetch, opaque origin (so `localStorage` is isolated and does not survive reloads in v1). The ONLY channel from the iframe to atrium is `window.parent.postMessage(envelope, '*')`. The envelope is a Zod-validated discriminated union by `type`:

```ts
type IframeMessage =
  | { type: "send";   payload?: unknown; framing?: string; target?: string }
  | { type: "atrium"; uri: string }      // must start with "atrium://"
  | { type: "log";    level: "info" | "warn" | "error"; message: string }; // debugging only
```

- **`send`** — sends the payload back to the agent. Semantically identical to canvas's `send_to_agent` action: atrium applies the framing template (note's `sendFraming` if `framing` is unset on the message), routes to the target pane (originating agent if `target` is unset), and injects the framed text into the recipient's stdin. `payload` is optional (Zod `.optional()`).
- **`atrium`** — invokes the given `atrium://` URI. Semantically identical to canvas's `atrium_command` action.
- **`log`** — debugging only. Routed to atrium's host devtools console (NOT visible to the agent that authored the HTML). Don't rely on this for production flows.

atrium's parent listener validates every message against the Zod schema and **drops malformed messages silently** (one-line `console.warn` in the host devtools). The parent also verifies `event.source === iframe.contentWindow` before processing, so other iframes / windows can't spoof messages.

Example HTML body (single self-contained file):

```html
<!doctype html>
<html>
<body>
  <h2>Confirm file deletion</h2>
  <ul id="files"><li>src/legacy.ts</li><li>tests/legacy.test.ts</li></ul>
  <button id="confirm">Confirm deletion</button>
  <button id="cancel">Cancel</button>
  <script>
    document.getElementById('confirm').onclick = () => {
      parent.postMessage({ type: 'send', payload: { decision: 'confirm' } }, '*');
    };
    document.getElementById('cancel').onclick = () => {
      parent.postMessage({ type: 'send', payload: { decision: 'cancel' } }, '*');
    };
  </script>
</body>
</html>
```

### Framing template syntax

The `--send-framing` flag (and the canvas `send_to_agent` action's `framing` param, and the html `{type:'send', framing}` envelope field) takes a template string with brace-substituted variables:

| Variable | Substitution |
|---|---|
| `{payload}`   | `JSON.stringify(payload, null, 2)` — pretty-printed JSON |
| `{noteId}`    | The note's UUID |
| `{noteTitle}` | The note's title |
| `{actionId}`  | **Reserved** — the current bridge implementation does NOT populate this; it passes through as the literal `{actionId}` text. Do not depend on it for production flows. |

Substitution is literal `{name}` → value (regex `/\{(\w+)\}/g`). Undefined variables pass through as their literal `{name}` text (so a misnamed `{ammount}` stays `{ammount}` in the output — useful for debugging). No Mustache, no Handlebars, no nested braces, no escape syntax.

Example:

```
--send-framing "Triage result for note '{noteTitle}' ({noteId}):\n\n{payload}"
```

Note the framing does NOT include the auto-prefix that `agent message` adds (`[Message from "X" via atrium]`). Whatever you set in `--send-framing` is the **entire wrapper** the recipient agent sees. If you want a sender-identity prefix, include it in the template yourself (e.g. `"User canvas response (from note '{noteTitle}'):\n\n{payload}"`).

### End-to-end worked example: triaging stale PRs

1. **You author the canvas** (in your turn, in response to "help me triage 40 stale PRs"):

   ```bash
   SPEC=$(jq -n --argjson rows "$(gh pr list --state open --limit 40 --json number,title,author --jq '[.[] | {key: ("pr_" + (.number|tostring)), title}]')" '{
     root: "rootCard",
     elements: ({
       rootCard: {type: "Card", props: {title: "Stale PR triage"}, children: [$rows[].key]}
     } + ($rows | map({(.key): {type: "Card", props: {title: .title}, children: []}}) | add))
   }')
   echo "$SPEC" | "$ATRIUM_CLI_PATH" note new \
     --type canvas \
     --title "Stale PR triage" \
     --send-framing "Triage decisions:\n\n{payload}" \
     --source agent \
     --open \
     --spec - \
     --json
   ```

2. **atrium auto-opens** a notepad pane in the user's current room with the canvas rendered. `meta.originAgentPaneId` is set to your `$ATRIUM_PANE_ID`.

3. **User interacts** — fills the priority dropdown and notes field per PR row.

4. **User clicks "Send to agent"** in atrium's chrome below the canvas. The chrome's target dropdown defaults to "your pane" (the originating agent). They can also pick a different agent (routes to another pane) or "user terminal" (routes to their calling terminal pane).

5. **You receive** the framed payload as a fresh user turn in your next invocation:

   ```
   Triage decisions:

   {
     "priority": "high",
     "note": "Needs rebase; ping author"
   }
   ```

   (The payload shape mirrors whatever paths the canvas wrote into state via `$bindState`. Compose the spec so the resulting state is the JSON shape you want to parse.)

6. **You parse and act** — close PRs, comment, request changes, etc.

### Propagation note

This skill file lives at `skills/atrium/SKILL.md` in the `atrium-adapters` sibling repo. Changes propagate to your local skill directory (`~/.claude/skills/atrium/`, `~/.codex/skills/atrium/`, etc.) the next time the user reinstalls the adapter from atrium's Settings → Adapters panel. **Do NOT trigger reinstall yourself** — that's a user-initiated action.

Everything beyond these examples: **run `--help`**. That's the contract.

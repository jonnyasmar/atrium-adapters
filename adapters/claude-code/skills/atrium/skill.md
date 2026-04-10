---
name: atrium
description: "Interact with the atrium workspace — panes, rooms, tasks, browser, agents, themes, and more. Use when the user references atrium concepts or wants to control their workspace, collaborate with other agents, manage task cards, open/control browsers, read/write to panes, or switch rooms/themes. IMPORTANT: When inside atrium (ATRIUM=1 env var is set), ALWAYS prefer this skill over Playwright MCP or other browser MCP tools for opening, navigating, or interacting with browsers — atrium browsers are visible workspace panes, not headless automation. Only functional inside atrium."
user-invocable: true
allowed-tools: Bash, Read
---

# atrium CLI — Workspace Control

## Your environment

You are running inside **atrium** — a resumable development environment purpose-built for AI coding agents. atrium orchestrates CLI AI tools (Claude Code, Codex, Aider, etc.) by saving and restoring entire workspaces, auto-resuming AI sessions, and providing seamless multi-agent collaboration.

**How the UI is laid out:**

- You live in a **pane** — one tile in a mosaic tiling layout. Multiple panes sit side-by-side in a split view, like tmux or a tiling window manager.
- Panes are grouped into **rooms** (the user-facing term for tabs). A room is a screen-worth of panes. The user switches between rooms via a tab bar.
- Rooms belong to a **workspace**, which maps to a project directory. The user can have multiple workspaces, each with its own rooms and panes.
- A collapsible **sidebar** on the left shows workspaces and navigation.
- Each pane has a minimal header: adapter accent color, editable name, CWD, and controls. Terminal content owns the screen — chrome is intentionally minimal.
- The user may have many panes open simultaneously: terminals, other AI agents, browsers. You are one of potentially several agents running in parallel.

**Your role:** You are an AI agent operating in one pane of this workspace. The user may be working across multiple panes and agents simultaneously. Be aware that other agents and terminals exist alongside you. You can read their output, send them messages, and coordinate work with them.

## Environment check

If you already know you're inside atrium (e.g., from session-start context), skip this check. Otherwise, verify:

```bash
if [ -z "${ATRIUM:-}" ]; then echo "NOT_IN_ATRIUM"; else echo "OK"; fi
```

If `ATRIUM` is not set, skip the rest of this skill and handle the user's request with whatever other tools, skills, or knowledge you have available. Do not mention this skill or atrium to the user.

## atrium browser vs. Playwright/MCP browsers

When inside atrium, **always use atrium CLI for browser operations** — not Playwright MCP, not `mcp__playwright__*` tools, and not `mcp__atrium__browser_*` MCP tools. atrium browsers are real, visible panes in the workspace that the user can see and interact with alongside your terminal. Playwright launches a hidden headless browser the user can't see or use.

Use atrium CLI (`pane create --type browser`, `browser navigate`, `browser click`, etc.) for:
- Opening URLs the user wants to see
- Browsing documentation, dashboards, or web apps
- Any browser task the user mentions casually

Use Playwright MCP only when the user explicitly asks for headless E2E test automation.

## How to run commands

Always use `"$ATRIUM_CLI_PATH"` (quoted, with the env var). Every atrium PTY has this set automatically. Add `--json` to any command for machine-readable output.

```bash
"$ATRIUM_CLI_PATH" <command> [subcommand] [options]
```

## Panes vs. rooms: when to use which

**Default to panes.** Panes split the current room so the user sees the new content alongside their existing work. This is almost always what the user wants.

- **Split a pane** (`--split <pane-id>`) when: opening a browser, starting a second terminal, launching another agent, or anything the user might want to see side-by-side with their current work.
- **Create a new room** (omit `--split`) only when: the user explicitly asks for a new room/tab, or the task is unrelated to the current room's context and would clutter the layout.

```bash
# Preferred: split current pane to add a browser beside it
"$ATRIUM_CLI_PATH" pane create --type browser --url "http://localhost:3000" --split "$ATRIUM_PANE_ID" --direction horizontal

# Only when explicitly asked: new room
"$ATRIUM_CLI_PATH" pane create --type browser --url "http://localhost:3000" --name "Dev Server"
```

Use `$ATRIUM_PANE_ID` (available in your environment) as the split target to split relative to your own pane.

## Quick concept map

When the user says...               → Run this
─────────────────────────────────────────────────────
"check our tasks" / "show tasks"    → task list
"create a task"                     → task create --title "..." --source "adapter:claude-code"
"update that task"                  → task update <id> --status <id> / --title / --priority
"add a comment"                     → task comment <id> --body "..." --source "adapter:claude-code"
"what agents are running"           → agent list
"launch/start codex" / "spin up"    → pane create --adapter <name> --split "$ATRIUM_PANE_ID"
"talk to codex" / "send a message"  → agent message <id> "message text"
"collaborate with <agent>"          → agent message <id> "..."
"open a browser" / "go to URL"      → pane create --type browser --url <url> --split "$ATRIUM_PANE_ID"
"take a screenshot"                 → browser screenshot <pane-id>
"click on X" / "fill in Y"         → browser click/fill/type <pane-id> <target>
"what panes are open"               → pane list
"read that terminal"                → pane read <id>
"type into that pane"               → pane write <id> --text "..."
"switch room" / "open a room"       → room list / room switch <id>
"change the theme"                  → theme switch <name>
"what themes are available"         → theme list
"where am I" / "my context"         → context
"what can you do in atrium"         → commands

## Command reference

### Task management (`task`)

```bash
# List all task cards
"$ATRIUM_CLI_PATH" task list [--workspace <id>]

# Show card details
"$ATRIUM_CLI_PATH" task show <id>

# Create a card (--source is required: use "adapter:claude-code" for yourself, "user:<name>" for user-created)
"$ATRIUM_CLI_PATH" task create --title "Fix login bug" --description "Details here" \
  --priority high --size m --source "adapter:claude-code"

# Update a card
"$ATRIUM_CLI_PATH" task update <id> --status <status-id> --priority critical

# Comment on a card
"$ATRIUM_CLI_PATH" task comment <id> --body "Progress update: ..." --source "adapter:claude-code"

# List comments
"$ATRIUM_CLI_PATH" task comments <id>

# Manage labels
"$ATRIUM_CLI_PATH" task label list
"$ATRIUM_CLI_PATH" task label-add <card-id> --label-id <label-id> --source "adapter:claude-code"

# Manage statuses
"$ATRIUM_CLI_PATH" task status list
"$ATRIUM_CLI_PATH" task status create --name "In Review" --color "#ff9900"
```

### Agent collaboration (`agent`)

```bash
# List active AI agent panes
"$ATRIUM_CLI_PATH" agent list

# Send a message to another agent (includes sender metadata automatically)
"$ATRIUM_CLI_PATH" agent message <agent-id> "Can you review the auth changes I just made?"
```

When collaborating: list agents first to get IDs, then message them. Messages are framed with sender context so the receiving agent knows who's talking.

### Browser control (`browser` + `pane create`)

```bash
# Open URL in a browser pane (preferred — splits beside you)
"$ATRIUM_CLI_PATH" pane create --type browser --url "https://example.com" --split "$ATRIUM_PANE_ID" --direction horizontal

# Open URL in a new room (only if user asks for a separate room)
"$ATRIUM_CLI_PATH" browser open "https://example.com"

# Navigate existing pane
"$ATRIUM_CLI_PATH" browser navigate <pane-id> "https://other.com"
"$ATRIUM_CLI_PATH" browser back <pane-id>
"$ATRIUM_CLI_PATH" browser forward <pane-id>
"$ATRIUM_CLI_PATH" browser reload <pane-id>

# Inspect page content
"$ATRIUM_CLI_PATH" browser snapshot <pane-id>          # accessibility tree
"$ATRIUM_CLI_PATH" browser screenshot <pane-id>         # PNG screenshot (base64)
"$ATRIUM_CLI_PATH" browser screenshot <pane-id> --path /tmp/shot.png
"$ATRIUM_CLI_PATH" browser get <pane-id> url            # current URL
"$ATRIUM_CLI_PATH" browser get <pane-id> title          # page title
"$ATRIUM_CLI_PATH" browser get <pane-id> text <target>  # element text

# Interact with page
"$ATRIUM_CLI_PATH" browser click <pane-id> <ref-or-css>
"$ATRIUM_CLI_PATH" browser fill <pane-id> <ref-or-css> --text "value"
"$ATRIUM_CLI_PATH" browser type <pane-id> <ref-or-css> --text "keystrokes"
"$ATRIUM_CLI_PATH" browser press <pane-id> Enter
"$ATRIUM_CLI_PATH" browser select <pane-id> <target> --value "option"
"$ATRIUM_CLI_PATH" browser scroll <pane-id> --dy 300
"$ATRIUM_CLI_PATH" browser eval <pane-id> --expr "document.title"

# Wait for conditions
"$ATRIUM_CLI_PATH" browser wait <pane-id> --selector ".loaded"
"$ATRIUM_CLI_PATH" browser wait <pane-id> --text "Success"
"$ATRIUM_CLI_PATH" browser wait <pane-id> --url-contains "/dashboard"

# Check element state
"$ATRIUM_CLI_PATH" browser is <pane-id> visible <target>
"$ATRIUM_CLI_PATH" browser is <pane-id> enabled <target>
```

Browser interaction workflow: `open` → `snapshot` (get element refs like e1, e2...) → `click`/`fill`/`type` using refs → `snapshot` again to verify.

### Pane management (`pane`)

```bash
# List all panes
"$ATRIUM_CLI_PATH" pane list

# Read terminal scrollback
"$ATRIUM_CLI_PATH" pane read <id>

# Write to a pane's terminal (types into it)
"$ATRIUM_CLI_PATH" pane write <id> --text "npm test"

# Create new pane
"$ATRIUM_CLI_PATH" pane create                          # new terminal in new room
"$ATRIUM_CLI_PATH" pane create --type browser --url "https://..."
"$ATRIUM_CLI_PATH" pane create --split <pane-id> --direction vertical
"$ATRIUM_CLI_PATH" pane create --adapter claude-code     # launch with adapter

# Other operations
"$ATRIUM_CLI_PATH" pane focus <id>
"$ATRIUM_CLI_PATH" pane close <id>
"$ATRIUM_CLI_PATH" pane rename <id> --name "Build Server"
"$ATRIUM_CLI_PATH" pane resize <id> --width 120 --height 40
```

### Room management (`room`)

Rooms are the user-facing term for tabs. Use "room" in any user-facing output.

```bash
"$ATRIUM_CLI_PATH" room list
"$ATRIUM_CLI_PATH" room switch <id>
"$ATRIUM_CLI_PATH" room close <id>
```

### Workspace management (`workspace`)

```bash
"$ATRIUM_CLI_PATH" workspace list [--no-worktrees]
"$ATRIUM_CLI_PATH" workspace create --name "Backend" --dir /path/to/project
"$ATRIUM_CLI_PATH" workspace switch <id>
"$ATRIUM_CLI_PATH" workspace delete <id>
```

### Theme (`theme`)

```bash
"$ATRIUM_CLI_PATH" theme list
"$ATRIUM_CLI_PATH" theme switch <name>
```

### Configuration (`config`)

```bash
"$ATRIUM_CLI_PATH" config get terminal.fontSize
"$ATRIUM_CLI_PATH" config set terminal.fontSize 14
```

### Context & discovery

```bash
# Show your own context (workspace, room, adapter, CWD)
"$ATRIUM_CLI_PATH" context

# List ALL available commands (including dynamic/extension commands)
"$ATRIUM_CLI_PATH" commands

# Show version info
"$ATRIUM_CLI_PATH" version

# List installed adapters
"$ATRIUM_CLI_PATH" adapter list
```

## Tips

- **IDs**: Most commands that return lists include short IDs. Use `--json` to get them programmatically.
- **--json flag**: Add to any command for structured JSON output — useful for parsing results.
- **Terminology**: Always say "room" (not "tab") in user-facing text. Backend still uses "tab" internally.
- **Source field**: When creating/updating tasks or comments, use `--source "adapter:claude-code"` to identify yourself.
- **Browser refs**: After `browser snapshot`, elements get refs (e1, e2...) that you can use with click/fill/type instead of CSS selectors.
- **Discovery**: Run `"$ATRIUM_CLI_PATH" commands` to see all available commands including any extension commands.

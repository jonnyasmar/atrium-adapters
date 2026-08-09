# Inline canvas fences in chat

Read this when you want the user to *do* something — pick, confirm, fill in, adjust — without leaving the conversation. You emit a fenced code block tagged `canvas` in an ordinary reply, and the chat transcript renders it in place as a live, interactive canvas that builds as you type it.

It is **not** a tool call and **not** a note. No CLI invocation, no file on disk, no extra pane. It is text you write, rendered where you wrote it.

**Where it renders:** the agent chat transcript — an `agent-chat` pane. In a terminal pane your output goes to a terminal emulator that renders no markdown at all; there the fence is just text on screen, and a canvas note is the right tool instead. `"$ATRIUM_CLI_PATH" context --json` reports your `paneType` if you're unsure.

**The spec format and component catalog are identical to canvas notes.** This file covers only what differs. For the `Spec` shape, the `$bindState` vs `$state` distinction, and the full component catalog, read `notes-interactive-ui.md` (sibling to this file). Don't guess component names.

## Grammar

````
```canvas
{ "root": "…", "elements": { … } }
```
````

- **Backticks**, and the info string is a language tag plus optional space-separated flags. `canvas` needs no flag.
- The body is **one JSON object — a whole canvas `Spec`** (`{ root, elements, state? }`), the same JSON that lives in a note's `note.canvas.json`. Not patch ops, not JSONL.
- **`canvas` is the only language that renders.** `ts`, `json`, `html`, `bash` and everything else stay ordinary code blocks, unchanged.
- Several canvas fences in one message are fine. Each is independent and owns its own state.
- Prose before and after the fence renders as normal markdown. Keep narrating around it.
- A canvas fence **nested inside a larger fence is not extracted**. To show a spec as source instead of rendering it, wrap it in a four-backtick fence.

## A working example

You've found three failing suites and want the user to choose before you spend a turn on the wrong one:

```canvas
{
  "root": "root",
  "elements": {
    "root": {
      "type": "Card",
      "props": { "title": "Which failure do I chase first?" },
      "children": ["body"]
    },
    "body": {
      "type": "Stack",
      "props": { "direction": "column", "gap": 16 },
      "children": ["pick", "why", "go"]
    },
    "pick": {
      "type": "Radio",
      "props": {
        "value": { "$bindState": "/target" },
        "options": [
          { "value": "pty-resize", "label": "PTY resize race — 3 tests" },
          { "value": "fts-index", "label": "FTS index drift — 1 test" },
          { "value": "ci-timeout", "label": "CI-only timeout — 2 tests" }
        ]
      },
      "children": []
    },
    "why": {
      "type": "Textarea",
      "props": {
        "label": "Anything I should know?",
        "value": { "$bindState": "/notes" },
        "rows": 3
      },
      "children": []
    },
    "go": {
      "type": "Button",
      "props": { "label": "Start there", "variant": "primary" },
      "children": [],
      "on": {
        "press": {
          "action": "send_to_agent",
          "params": { "payload": { "$state": "" } }
        }
      }
    }
  }
}
```

The user gets a card, picks a radio, optionally types a note, hits the button — and the state arrives in your next turn as `{ "target": "pty-resize", "notes": "…" }`.

## Fence, note, or plain markdown?

|  | inline `canvas` fence | canvas note | plain markdown |
|---|---|---|---|
| Where it appears | in the transcript, where you wrote it | its own notepad pane | in the transcript |
| Setup | none — type the fence | `note new --type canvas --open` | none |
| Survives app restart | the spec re-renders; **the user's input is gone** | yes, spec and state both | yes — it's transcript text |
| Changing it later | emit a new one further down | `note canvas-patch <id>`, any turn | — |
| Input back to you | `send_to_agent` → this pane | `send_to_agent` → any pane | none |
| Costs the user | nothing | a pane and a file | nothing |

**Reach for the fence** when the interaction belongs to *this turn*: a three-way choice you need answered before you continue, a config you want tweaked before you apply it, a plan you want approved, a small dashboard that assembles while you think out loud. Its whole value is that it costs the user nothing — no pane appears, no file lands in their notes, and it scrolls away with the rest of the conversation when it's spent.

**Reach for a canvas note** when the artifact outlives the question: the user needs it open in a pane beside their work, they'll want it tomorrow, you'll mutate it across several turns with `canvas-patch`, another agent has to point at it, or the form is long enough that losing it to a restart would be rude.

**Reach for plain markdown** for anything the user only reads. A table is a table. If nothing binds to state and nothing sends anything back, a canvas is a heavier surface with no payoff — write the markdown.

The failure mode in each direction: a fence where a note belonged loses the user's work on the next restart; a note where a fence belonged litters their workspace with panes and files they have to clean up.

## Write it so it streams well

The transcript closes your unterminated fence and repairs the half-written JSON on every frame, so the canvas assembles in front of the user as the tokens arrive. You get that for free — but the order you write the spec in decides what the build looks like.

- **Put `root` first and define the root element immediately after.** Nothing renders until `root` names an element that exists; everything before that point is a blank frame.
- **Declare children before they exist.** A parent listing `"children": ["summary", "form", "submit"]` renders the ones that have landed and skips the rest — each pops in as you write it. That's the build the user wants to watch.
- **Write elements in the order they should appear**: shells first (`Card`, `Stack`), then contents, top to bottom.
- **Don't minify.** Newlines between elements make the build read as a sequence of steps instead of one shudder.
- **Close the fence.** An unterminated fence leaves the artifact in its streaming state.

Once the JSON parses cleanly the strict parser takes over — the same one notes use. A dangling child reference in a *finished* spec is your bug and surfaces as a missing element; it is not repaired for you.

## State is ephemeral

Everything the user types into an inline canvas lives in memory, keyed to the message that produced it.

- It survives scrolling away and back.
- It is **lost on app restart**, and it is never written to disk. The canvas itself returns — your message text is journaled — but it returns empty.
- There is no `state.json`, no history, no file to read back — nothing to hand another agent.

**Never tell the user their input is saved.** If it has to outlive the session, that's a canvas note.

## Actions

The same two custom actions as notes (`send_to_agent`, `atrium_command`), with one routing difference:

- **`send_to_agent` routes back to the pane that emitted the fence.** There's no note id and no target picker — omit `target`.
- There's no note to carry a `sendFraming`, so framing defaults to `{payload}`. Pass `framing` in the action params if you want a wrapper. `{noteId}` / `{noteTitle}` have nothing to resolve to here.
- The turn arrives to you with a system header — `[from inline chat artifact in pane <paneId>]`, a blank line, then the payload. It's the same envelope shape as a canvas note's, so you can recognise which surface a submission came from without tracking it yourself.
- `atrium_command` is unchanged — see the URI table in `notes-interactive-ui.md`.
- **You must include a submit affordance.** Nothing renders a default "send" footer. A canvas with no `send_to_agent` button is a display, not a form — which is fine if that's what you meant, and a dead end if it isn't.
- Action params read state with `{"$state": "/pointer"}`; `$bindState` is render-time only. Same rule, same trap, as notes.

## Reserved flags

The info string carries space-separated flags after the language (`` ```canvas ``, `` ```html render ``). One flag is reserved:

- **`render`** — the future opt-in for languages that collide with ordinary code blocks. Agents emit HTML code blocks constantly and expect a code block, so a language like `html` will have to ask for rendering explicitly rather than get it by default.

It parses today and nothing consumes it. **`` ```html render `` renders nothing right now** — it's an HTML code block like any other. Don't put `render` on a canvas fence; it's unnecessary and it will read as a mistake.

## When it comes out as a plain code block

Work down this list before assuming the feature is broken:

- **Wrong tag.** Only `canvas` renders. `json`, `canvas-spec`, `Canvas` do not.
- **Not assistant text.** Only your own streamed reply renders. Canvas fences in user messages, thinking blocks, plan cards, and framed agent-to-agent messages stay code blocks.
- **Not the main transcript.** Only the pane's own transcript renders artifacts. A reply read back inside a task drill-in or the task viewer stays a code block, so a fence you emit as a subagent won't render where the user reads your work.
- **Not a chat pane.** A terminal pane renders no markdown at all.
- **Nested in an outer fence.** Four-backtick wrappers suppress it deliberately.
- **Inline artifact rendering is switched off.** It's on by default and there is no toggle in Settings yet, so this is unlikely — but the preference exists and a support instruction could have flipped it.

A spec whose JSON never parses is a different failure: you get an error in the artifact frame, not a code block. Use the frame's **Show source** toggle to read back exactly what you emitted.

## What NOT to do

- **Don't use a fence for anything the user needs later.** It dies with the transcript — use a note.
- **Don't emit patch ops in a canvas fence.** The body is a whole spec. `canvas-patch` is the notes path.
- **Don't try to send one to another agent.** `agent message` bodies are framed, not rendered.
- **Don't re-emit a whole canvas each turn to update it.** A fence belongs to the message that produced it; a "new version" is a second artifact further down the transcript. Iterating on one live surface is what a note plus `canvas-patch` is for.
- **Don't restate the canvas in prose.** The artifact is the message. One sentence of setup, then let them use it.
- **Don't reach for it for static content.** A `Card` full of `Text` is markdown with extra steps.

## Propagation note

This file lives at `skills/atrium/references/chat-canvas-fence.md` in the `atrium-adapters` sibling repo and propagates to your local skill directory (`~/.claude/skills/atrium/`, `~/.codex/skills/atrium/`, …) the next time atrium boots. **Don't trigger a reinstall yourself** — that's a user action.

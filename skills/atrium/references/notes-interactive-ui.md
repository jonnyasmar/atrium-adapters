# Notes — canvas & html interactive UIs

This reference is the deep-dive companion to the `## Notes` section of the parent `SKILL.md`. Read it when you're actually authoring a canvas or HTML note — for everyday CLI work it isn't needed.

atrium notes have four modes. Two (markdown, sketch) are agent-readable content. Two (**canvas**, **html**) are **interactive UIs the user fills in and sends back to you**. Use canvas/html when you need the user to:

- Triage a list (e.g. 40 PRs with a priority dropdown + notes field per row).
- Confirm a destructive operation with structured input (e.g. select which files to delete).
- Provide multi-field structured feedback (e.g. a bug-report form).
- Anything where a wall of text + numbered list in the terminal would be high cognitive load.

The bidirectional model:

1. You author a UI (JSON spec for canvas, raw HTML for html) and ship it via `atrium note new`.
2. atrium auto-opens a notepad pane in the user's current room showing the UI (when you pass `--open`).
3. The user interacts (fills fields, clicks buttons).
4. **You MUST include a submit affordance in your spec** — atrium does not render a default "Send to agent" footer. For canvas: a `Button` with `on.press: { action: "send_to_agent", params: { payload: { "$state": "" } } }`. For html: a `<button onclick="parent.postMessage({type:'send', payload:{...}}, '*')">`. Without one, the user has no way to send the form state back. Including multiple submit buttons (e.g. "Approve" vs "Reject" with different payloads) is fine — each fires its own `send_to_agent` with its own params.

## Choosing canvas vs html

- **canvas** — declarative JSON spec rendered by `@json-render/react`. Safer (no agent-authored JS; components are predefined), more structured, and the user's form state lives in the renderer's state model (note-scoped). Use this for **everything except cases where the curated component set can't express what you need**.
- **html** — agent-authored HTML in a sandboxed iframe (`sandbox="allow-scripts"`). Use when the canvas component set can't express your layout / interaction (custom CSS, agent-authored JS-driven flows). Stateless across pane reloads in v1 — the iframe has an opaque sandbox origin, so `localStorage` is isolated and there is no persistence layer behind the iframe yet.

## CLI invocation

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

- `--type {markdown|sketch|canvas|html}`. For `canvas` you MUST pass `--spec`; for `html` you MUST pass `--body`. The two are mutually exclusive (clap-enforced) and rejected for the other two types.
- `--spec` / `--body` accept either a file path or `-` (read piped stdin). Refusing TTY stdin is intentional — it avoids the "agent froze waiting for input" footgun.
- `--send-framing "<template>"` stores the framing in `meta.json` as `sendFraming`. The Send-to-agent chrome reads it back. Variables: `{payload}`, `{noteId}`, `{noteTitle}`, `{actionId}` — see **Framing template syntax** below.
- `--open` is opt-in (default false). For canvas/html you almost always want it — without `--open` the note is durable on disk but no pane is opened.
- `--source agent` flags the note as agent-authored in `meta.json` so the user can filter or hide agent notes in bulk. Use it whenever you author a note autonomously.
- The CLI captures `$ATRIUM_PANE_ID` from your environment and stores it as `meta.originAgentPaneId`, so the Send-to-agent chrome defaults its target dropdown to "your pane".
- Pass `--json` on every invocation; you are an agent parsing output.

## Canvas spec format

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

### Reading state — two different directives

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

## Streaming a canvas spec

**Default agent behavior for canvas: open the canvas in a pane beside yourself FIRST, then stream the spec into it.** A canvas that builds in front of the user is a collaboration; a canvas that appears fully-formed at the end is just a generated document. Default to live; one-shot writes are the exception (use when the user explicitly asked for a *deliverable*, not a live build).

The two-step flow:

```bash
# 1. Open an empty canvas beside the agent — the user sees the pane immediately.
NOTE_ID=$(atrium note new --title "Plan: X" --type canvas --open --source agent \
  --spec - --json <<'EOF' | jq -r .id
{
  "root": "rootStack",
  "elements": {
    "rootStack": {
      "type": "Stack",
      "props": { "direction": "column", "gap": 16 },
      "children": []
    }
  },
  "state": {}
}
EOF
)

# 2. Stream RFC 6902 patches into the now-visible note as you generate them.
{
  echo '{"op":"add","path":"/elements/heading","value":{"type":"Heading","props":{"text":"Plan"},"children":[]}}'
  echo '{"op":"add","path":"/elements/rootStack/children/-","value":"heading"}'
  echo '{"op":"add","path":"/elements/section1","value":{"type":"Card","props":{"title":"Step 1"},"children":[]}}'
  echo '{"op":"add","path":"/elements/rootStack/children/-","value":"section1"}'
  # ... emit more ops as you think
} | atrium note canvas-patch "$NOTE_ID"
```

### Wire format

- **One RFC 6902 op per line of JSONL on stdin.** Each line is a standalone JSON object: `{"op":"add|remove|replace|move|copy|test","path":"/json/pointer","value":...,"from":"/path"}` (`value` for add/replace/test, `from` for move/copy).
- Alternative input modes for the same verb:
  - `atrium note canvas-patch <id> --op '<json>'` — single op, one-shot. Use for scripted edits to an existing canvas.
  - `atrium note canvas-patch <id> --from-file <path>` — JSONL file, single batch. Use for prebuilt patch sets.
- atrium **throttles disk writes server-side to ~50ms** (20 Hz). Emit patches as fast as you generate them — the throttle protects the FTS index and event channel from flooding, without making the experience feel laggy (well below human flicker threshold).
- Patches target the **flat element map** form documented in **Canvas spec format** above (`root` + `elements: { id: {type, props, children: ["id"]} }` + optional `state`). Patches against `/state/foo` seed the form state — useful for setting initial Select values, etc., mid-stream.

### Order tolerance

Streaming patches are forgiving — you don't have to emit elements in strict dependency order:

- **Forward references work.** A parent can declare `"children": ["futureCard"]` before `/elements/futureCard` exists in the map. The Renderer renders nothing for the missing id until the element lands in a later patch.
- **Partial-path adds auto-create intermediate parents.** `add /elements/foo/props/text "hi"` succeeds even if `foo` doesn't exist — the patch crate creates `foo` as a partial object. Cost: that element is structurally invalid (no `type`) until you fill it in.
- **`test` op mismatches don't abort the batch.** Failed ops are logged and skipped server-side; the stream continues. This is by design — agents emit speculatively, and a stalled half-built canvas is worse than a noisy stream.
- **Empty stdin lines are ignored** — safe to use blank lines for readability in long pipelines.

### Common patterns

- **Skeleton-first**: emit the layout structure (Stacks, Cards) with empty `children`, then fill the children in. The user sees the shape land immediately and watches each section populate.
- **State-bound inputs**: emit `Input` / `Textarea` / `Select` elements with `"value": {"$bindState": "/fieldName"}`. The user can start typing as soon as the input appears — typed values survive subsequent patches because the Renderer's state model is separate from the spec.
- **Cleanup mid-stream**: if you change your mind about an element, emit `{"op":"remove","path":"/elements/foo"}` plus `{"op":"remove","path":"/elements/parent/children/<index>"}` to retract it. The user sees the removal smoothly.

### When NOT to stream

- If the user explicitly asked for a canvas *deliverable* (e.g. "give me the canvas spec for X" — they want the artifact, not the build process), use `atrium note new --type canvas --spec <full-json>` and skip the patch stream entirely.
- If the canvas is trivially small (3-4 elements), a one-shot `note new --spec` is fine. Streaming below a couple seconds of build time isn't a meaningful UX win.

## The component catalog

atrium implements the **full json-render standard catalog** — all 41 components from json-render.dev plus `Label` (atrium-specific for a11y pairing). Most components map to a corresponding atrium primitive (`Button` wraps `ui/button`, `Switch` wraps `ui/switch`, `Checkbox` wraps `shared/Checkbox`, `Dialog` wraps `ui/dialog`, `DropdownMenu` wraps `ui/dropdown-menu`) so they inherit any future styling updates automatically.

**Layout & display:**

| Component | Key props |
|---|---|
| `Stack`     | `direction?: "row"\|"column"`, `gap?: number`, `padding?: number`, `align?: "start"\|"center"\|"end"\|"stretch"\|"baseline"`, `justify?: "start"\|"center"\|"end"\|"between"\|"around"\|"evenly"`. Row stacks default `align: "center"`; column stacks default `align: "stretch"`. |
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
| `DropdownMenu` | `label: string`, `items: { value, label }[]`, `value?` (bind). Picking an item writes its value through `value` and fires `select`. |
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

## Custom actions (atrium-specific)

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

  **Params go in the URI's query string** — not as siblings of `uri` in the action binding. The `atrium_command` action only forwards the URI; the protocol parser reads params from `?key=val&key=val` on the URI itself. URL-encode any values that need it (spaces, slashes, etc.).

  ```json
  {"action": "atrium_command", "params": {
    "uri": "atrium://commands/notepad.open?noteId=019e1d…&workspaceId=25b5cba7-…"
  }}
  ```

  ❌ Wrong (silently strips `noteId`/`workspaceId`, then the command fails with "missing required param: noteId"):

  ```json
  {"action": "atrium_command", "params": {
    "uri": "atrium://commands/notepad.open",
    "noteId": "019e1d…",
    "workspaceId": "25b5cba7-…"
  }}
  ```

  (Note: there is NO `notes.open` or "open the notes finder" command today. To create a note from a canvas action, use `pane.create` with the appropriate type or wire `send_to_agent` with a "please create a note" instruction.)

## HTML postMessage protocol

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

## Framing template syntax

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

## End-to-end worked example: triaging stale PRs

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

## Propagation note

This reference file lives at `skills/atrium/references/notes-interactive-ui.md` in the `atrium-adapters` sibling repo. The parent SKILL.md and this file both propagate to your local skill directory (`~/.claude/skills/atrium/`, `~/.codex/skills/atrium/`, etc.) automatically the next time atrium boots — atrium re-fetches both at every launch and hash-gates the writes. **Do NOT trigger reinstall yourself** — that's a user-initiated action when the propagation path breaks.

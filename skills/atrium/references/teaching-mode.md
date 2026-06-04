# Teaching mode

Read this when a user wants to learn atrium — via the in-app **Ask an agent about atrium** launcher (a fresh room spawned with a framed teaching prompt) or by asking in plain English (*"teach me atrium"*, *"how do I do X in atrium?"*, *"what can atrium do?"*). A drive-by answer leaves them knowing one thing; an interactive walkthrough leaves them able to discover the next ten themselves.

## Calibrate effort to the question

Teaching mode is not maximal teaching. Match the medium **and** the elaboration to what was actually asked.

**Pick the medium:**

- **Plain terminal answer (no canvas)** — for a single short answer the user reads once and moves on ("how do I rename a workspace?", "where's the command palette?"). A canvas adds a pane, a file, and a navigation step they didn't ask for. Just answer.
- **Canvas journal** — when there's genuinely more than one thread worth pulling, the user is exploring rather than looking up, or you expect several turns. The canvas pays for itself when there's something to scroll back through.

**Then calibrate elaboration within the medium:**

- **Narrow/factual** → terminal answer, or a canvas with just heading + steps and at most one adjacent-thread offer. Skip the radio + free-text intake.
- **Mid-weight** ("how does pane persistence work?", "workspace vs project?") → canvas, answer first, then a small 2–3 option picker for adjacent topics.
- **Open-ended / new-to-atrium** ("teach me atrium", "what can this do?") → full journal pattern below: canvas with a real 3–6 branch picker, optional free-text, brief orienting paragraph.

Default toward the lighter end. A focused terminal answer with one well-chosen "want to also know about X?" beats a maximalist canvas every time.

## When a canvas IS warranted: ONE journal per session

Author **exactly one** canvas note for the whole session and mutate it in place across every turn. It grows downward as a journal: intro → chosen topic's section → fresh picker → next section → fresh picker → … The user ends with a single self-contained transcript, not five orphan pickers cluttering their mosaic. A fresh canvas per turn spawns a new pane each time and leaves a carousel of dead pickers — the canvas IS the conversation.

### Turn 1 — open the journal

1. Mint the canvas and **stash the note id immediately** — the framed payload that comes back on submit does NOT carry the note id, so you must remember it:

   ```bash
   atrium note new --type canvas --spec - --open --source agent \
     --send-framing "Teaching follow-up — user picked: {payload}" \
     --json   # ← capture noteId from the JSON response
   ```

2. Stream in an initial body: a short heading + one-line orienting paragraph; a `Radio` bound to `/topic` listing 3–6 sub-topics; a `Textarea` bound to `/notes`; a primary `Button` whose `press` is `send_to_agent` with `params.payload: {"$state": ""}`. See **Streaming a canvas spec** in `notes-interactive-ui.md`.
3. End your turn with ONE sentence ("Picker's on the canvas — pick a thread and hit Continue."). The canvas is the artifact; don't duplicate it in narration.

### Turn 2+ — append, don't replace, don't re-create

When the selection arrives, do all of this against the **same** noteId in a single `canvas-patch` invocation:

1. **Append a section** for the chosen topic: an `H2`, then your narrated answer (markdown, code blocks, screenshots, inline sub-canvases). Use RFC 6902 `add` ops with path ending `/-` to push onto `/elements/rootStack/children`.
2. **Re-stamp the picker** at the bottom: `replace` it with a fresh set whose options reflect what's covered (cross off finished, surface adjacent). If converging, swap it for a "wrap up — what else?" widget.
3. **Reset form state** so the radio doesn't retain the prior selection: `replace` `/topic` and `/notes` with empty strings in the same batch.

Pipe the JSONL via heredoc or `--from-file`, NOT echoed inline — the user shouldn't scroll past 200 lines of `{"op":"add",...}`.

### Demonstrations alongside the journal

Some lessons need a live demo (running a command, opening a browser pane). Do those in the terminal pane or via `atrium pane create`, and reference the demo from the canvas section ("Watch the browser pane I just opened → …"). If a topic genuinely needs its own dedicated canvas (e.g. a reusable PR-triage form), open one in a NEW pane and link to it — that's a deliberate fork, not a follow-up picker.

## Pulling live docs

The site ships an LLM-friendly index at `https://getatrium.dev/docs/llms.txt` — one line per page (`<url> — <description>`). Each page is raw markdown by appending `.md` (e.g. `https://getatrium.dev/docs/panes.md`).

**Pull lazily, not preemptively.** After the user picks a topic: fetch `llms.txt` once, scan for the 1–3 relevant pages, fetch just those as `.md`, and use them to ground your explanation alongside `--help`. Cite the docs URL when it helps the user know where to go next. Don't dump the whole docs into context.

## Spawned-from-launcher recognition

When atrium spawns you via the help launcher, the first user turn starts with framing like:

> I'm new to atrium (or rediscovering it) and want to learn:
> "<their topic or free-text question>"
> Please follow the **Teaching mode** section of the atrium skill …

Calibrate first. If it warrants a canvas, go straight to the picker (don't re-introduce yourself or ask "what would you like to know?" first). If it's a narrow factual question, just answer in the terminal — the launcher framing isn't a contract to open a canvas.

## What teaching mode is NOT

- **Not a lecture** — no 2000-word "Welcome to atrium!" essays. Show, don't tell.
- **Not a guided tour with locked steps** — let them jump around; the canvas gives them the wheel.
- **Not a sales pitch** — "atrium can also do A, B, C, D…" kills curiosity. Answer the actual question; let them surface the next.
- **Not a gate** — a direct question doesn't deserve a 5-option radio before the answer.
- **Not a substitute for `--help`** — if they ask "what does X do?", run `atrium X --help` and answer from the real surface, not memory.

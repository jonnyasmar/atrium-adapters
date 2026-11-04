# Designing a director's dashboard

Your dashboard is a canvas note in your dock's Overview, next to atrium's live blocks (Chats, Work, Browser, Routines, Attached). The owner glances at it in a dock about 350 px wide, in a wide pane, and on the phone. Make it something they read in five seconds, not a document. The spec format and every component's props are in `notes-interactive-ui.md`; this is how to use them on a board.

## The rules

1. **Status first.** The top of the board answers "how is it going, and do you need me?": a heading for what you're working towards, one muted line that says when you last updated it, and a status `Badge` (`warning` while something waits on the owner). Under it, at most four `Metric` tiles for numbers that matter in your domain and appear nowhere else on the board, each with a label of two or three words and, where you can, a `change` or a denominator. No such numbers, no strip.
2. **One idea per card.** A card is a section (In flight, Up next, Decided) or a single ask. Never put two topics in one card, and never put a card inside a card: the padding eats the dock's width.
3. **Show, don't tell.** Prefer the visual component to a sentence about it:
   - a number → `Metric`; a state → `Badge`; how far along → `Progress` (its `label` carries the words);
   - a list with attributes (queue, roadmap, options) → `Table`, three columns at most;
   - a trend → `LineGraph`, a comparison → `BarGraph`;
   - a timeline, pipeline or diagram the catalog can't draw → an `Html` block (keep it display-only);
   - good, caution and bad → `success`, `warning` and `destructive` variants, the same way everywhere.
4. **No prose walls.** One or two lines per item: at most about 140 characters in a `Text`, which is two lines in the dock. Background, reasons and lists go into a `Collapsible` (one block) or an `Accordion` (one panel per item), closed by default. A `Text` shows no line breaks, so a list typed into one runs together: make each item its own element or a `Table` row. If you are writing a paragraph, it belongs in your notebook, not on the board.
5. **Only what you know.** The live blocks already show every chat, delegation, browser, routine and attached item with its state. Never list those, their states or counts of them. The board holds what only you know: what waits on the owner, the goals behind the work, what's next, what was decided, and the context you work from. No IDs, paths, commands or worker names: outcomes, in the owner's words.
6. **Built for narrow.** Lay out tiles with a `Grid` and `minColumnWidth` (about 120 for metrics, 260 for cards), never a fixed `columns`: the same grid is one column in the dock and on the phone and several in a wide pane. A row holds two buttons at most, with labels of one to three words. Tables keep cells short; a cell that wraps to three lines is a sign the item needs its own card.

## Sections

Keep this order. A new board starts with every section saying it's empty; once yours fills in, drop a section that stays empty rather than keep it for show.

| Section | What goes in it | Shape |
|---|---|---|
| Header | What you're working towards, when you last updated, overall status | `Heading` + muted `Text`, `Badge`; a metric strip under it |
| Needs you | Questions only the owner can answer, and things only they can do | a `Card` per ask, titled with what you need (`Decide: …`, `Check: …`): the question in a line, details folded, a free-text field, two buttons at most. With nothing waiting, one card that says so |
| In flight | The goals and projects you're moving, beyond each delegation | `Progress` per goal when you can count it ("3 of 4 blockers fixed"); otherwise a `Table` (goal, stage) |
| Up next | What starts next, in order | `Table` (#, item, when) |
| Decided | The last five decisions, newest first | `Accordion`: one title per decision, starting with its date, details in its panel |
| Context | Standing facts, constraints, links | a closed `Collapsible` |

A section is a `Card` with a short `title`; use its `description` only when the title needs a word of help. Give elements stable, readable ids (`ask-store`, `goal-launch`, `decided-accounts`), so a later `canvas-patch` can find them. Every button of an ask sends the same shape, `{"ask": "<id>", "answer": "<value>", "note": {"$state": "/asks/<id>"}}` (a to-do's button answers `"done"`), so the owner's answers read the same way every time.

## Keeping it current

- **Update when something changes, not every turn:** a question comes up or is answered, a goal moves a stage, a decision is made, the plan's order changes. Touch the "Updated" line each time.
- **Patch the section, not the board:** `atrium note canvas-patch <id>` with a few ops (add an ask, move it to Decided, bump a `Progress` value). Rewrite the whole board with `atrium note write <id>` only when its shape changes.
- **Prune as you go.** An answered question leaves Needs you the same update (its outcome goes to Decided). Decided keeps the last five; older ones go to your notebook. Up next stays at five rows or fewer.
- **Look at it after every change:** `atrium note preview <id>` draws the board with atrium's own renderers, as the dock shows it, at 380 and 760 px, and prints the PNG paths. Open them and fix what reads badly: a line that wraps three times, a crowded row, a section that says nothing, a wall of text. It needs atrium open on this Mac.
- **Read the board check.** `note preview`, and `note write` or `canvas-patch` on your dashboard, warn about what a check can spot by itself: a `Text` over 300 characters, line breaks in a `Text`, more than three `Text`s in a row, a `Grid` with fixed `columns`, a `Card` inside a `Card`, a board with no visual at all. Warnings never block a write; fix them anyway.

## Patterns

Each pattern is a set of `elements` to merge into your board; the root `Stack` (`"direction": "column"`, `"gap": 12`) lists the section ids in order. Every element takes `"children": []` when it has none.

### Status header and metric strip

```json
{
  "header": {"type": "Stack", "props": {"direction": "row", "justify": "between", "align": "start", "gap": 8}, "children": ["header-text", "status"]},
  "header-text": {"type": "Stack", "props": {"direction": "column", "gap": 2}, "children": ["focus", "updated"]},
  "focus": {"type": "Heading", "props": {"text": "App Store launch", "level": 3}, "children": []},
  "updated": {"type": "Text", "props": {"content": "Updated Tue 3 Nov, 15:10", "tone": "muted"}, "children": []},
  "status": {"type": "Badge", "props": {"text": "Waiting on you", "variant": "warning"}, "children": []},
  "metrics": {"type": "Grid", "props": {"minColumnWidth": 120, "gap": 8}, "children": ["m-testers", "m-build", "m-crash"]},
  "m-testers": {"type": "Metric", "props": {"label": "Beta testers", "value": 14, "change": "+3 this week", "changeType": "positive"}, "children": []},
  "m-build": {"type": "Metric", "props": {"label": "TestFlight build", "value": "0.357"}, "children": []},
  "m-crash": {"type": "Metric", "props": {"label": "Crash-free", "value": "99.6", "suffix": "%", "change": "+0.4", "changeType": "positive"}, "children": []}
}
```

### An ask in Needs you

Its own card, titled with what you need: one line of question, the details folded, a free-text field that every button sends along, and the recommendation as the primary button.

```json
{
  "ask-store": {"type": "Card", "props": {"title": "Decide: App Store choices"}, "children": ["ask-store-q", "ask-store-more", "ask-store-note", "ask-store-actions"]},
  "ask-store-q": {"type": "Text", "props": {"content": "15 choices, from privacy label to age rating. Take my picks?"}, "children": []},
  "ask-store-more": {"type": "Collapsible", "props": {"title": "My picks"}, "children": ["ask-store-picks"]},
  "ask-store-picks": {"type": "Table", "props": {"columns": [{"key": "choice", "label": "Choice"}, {"key": "pick", "label": "I'd pick"}], "rows": [{"choice": "Age rating", "pick": "4+"}, {"choice": "Review account", "pick": "Sample mode"}]}, "children": []},
  "ask-store-note": {"type": "Input", "props": {"placeholder": "Or tell me something else", "value": {"$bindState": "/asks/store"}}, "children": []},
  "ask-store-actions": {"type": "Stack", "props": {"direction": "row", "gap": 8}, "children": ["ask-store-yes", "ask-store-talk"]},
  "ask-store-yes": {"type": "Button", "props": {"label": "Take your picks", "variant": "primary"}, "on": {"press": {"action": "send_to_agent", "params": {"payload": {"ask": "store", "answer": "accept", "note": {"$state": "/asks/store"}}}}}, "children": []},
  "ask-store-talk": {"type": "Button", "props": {"label": "Walk me through", "variant": "outline"}, "on": {"press": {"action": "send_to_agent", "params": {"payload": {"ask": "store", "answer": "walk-through", "note": {"$state": "/asks/store"}}}}}, "children": []}
}
```

A to-do for the owner has the same shape (`Check: …`): the task in a line, a checklist folded into a `Collapsible`, and a "Done" button that answers `"done"`.

### In flight and Up next

```json
{
  "work": {"type": "Grid", "props": {"minColumnWidth": 260, "gap": 12}, "children": ["inflight", "next"]},
  "inflight": {"type": "Card", "props": {"title": "In flight"}, "children": ["goal-launch", "goal-disk"]},
  "goal-launch": {"type": "Progress", "props": {"label": "App Store submission · 3 of 4 blockers fixed", "value": 3, "max": 4}, "children": []},
  "goal-disk": {"type": "Progress", "props": {"label": "Disk cleanup · 120 of 150 GB freed", "value": 120, "max": 150}, "children": []},
  "next": {"type": "Card", "props": {"title": "Up next"}, "children": ["next-table"]},
  "next-table": {"type": "Table", "props": {"columns": [{"key": "n", "label": "#"}, {"key": "item", "label": "Item"}, {"key": "when", "label": "When"}], "rows": [{"n": 1, "item": "Director head in the Dynamic Island", "when": "After the iPhone queue"}, {"n": 2, "item": "Phone refuses blocked addresses", "when": "Next"}]}, "children": []}
}
```

### Decision log

```json
{
  "decided": {"type": "Card", "props": {"title": "Decided"}, "children": ["decided-log"]},
  "decided-log": {"type": "Accordion", "props": {"type": "multiple", "items": [{"value": "accounts", "title": "3 Nov · Limited chats switch accounts"}, {"value": "disk", "title": "2 Nov · Clear old build leftovers"}]}, "children": ["decided-accounts", "decided-disk"]},
  "decided-accounts": {"type": "Text", "props": {"content": "Even on a hand-picked account, when its auto-continue is set to switch accounts.", "tone": "muted"}, "children": []},
  "decided-disk": {"type": "Text", "props": {"content": "Kept: the Colima VM, Android tools, and worktrees with unsaved edits.", "tone": "muted"}, "children": []}
}
```

### A timeline in an Html block

For a shape the catalog can't draw. It belongs inside a section (add its id to In flight's `children`), not between them. It shows as a snapshot in the owner's theme; draw with the theme tokens (`chat-html-pages.md`) and keep anything the owner answers in native components.

```json
{
  "timeline": {"type": "Html", "props": {"title": "Launch timeline", "height": 36, "html": "<div style=\"display:flex;gap:6px;font:12px var(--font-sans);color:var(--text)\"><div style=\"flex:1\"><div style=\"height:6px;border-radius:3px;background:var(--success)\"></div>Blockers</div><div style=\"flex:1\"><div style=\"height:6px;border-radius:3px;background:var(--warning)\"></div>Review build</div><div style=\"flex:1\"><div style=\"height:6px;border-radius:3px;background:var(--hairline)\"></div>Submit</div></div>"}, "children": []}
}
```

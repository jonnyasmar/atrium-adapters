# atrium HQ: commands for directors and staff

atrium's director and staff rules say what to do and name the command for it. This is the reference for those commands' flags and formats. `--help` on any of them shows the full surface.

## Delegating

```bash
"$ATRIUM_CLI_PATH" task delegate --title "<title>" --brief "<goal, context, constraints, what done looks like>" (--to <staff-slug> | --adapter <name>) \
  [--project <project>] [--path <subfolder>] [--also <project>]...
```

- `--to <slug>` hands it to a staff member (`hq staff` lists them). For a general worker, leave out `--to` and pass `--adapter <name>`: the CLI it runs on, e.g. `claude-code`. A name that isn't a staff member's is refused, and so is a director's: hand a director work with `hq assign` (below).
- `--project <name>` (or `--workspace`): the project to work in, by id, prefix or name. A director that names none works in its roster's primary project; with a roster but no primary it is asked to name one, and with no roster the work stays in HQ and the answer says so.
- `--path <subfolder>`: a folder inside the project (`atrium-mobile`). The worker starts there, so brains that read instructions only from their folder up (Codex, Pi, OpenCode, Antigravity) see that folder's own `AGENTS.md`.
- `--also <project>` (repeatable): related projects the work touches. The worker gets their cards, a line naming the instruction file to read before editing there, and their folders where its brain takes them: Claude Code loads their `CLAUDE.md`, rules and skills (not an `AGENTS.md`); Copilot only their `*.instructions.md`; Codex may write there but reads only its own project's `AGENTS.md`; an ACP brain only when it offers extra folders; Pi and OpenCode get the card and the line alone. With `--path`, the project's own top folder is one of them, so the worker can still work across the project.
- `--brief-file <path>` reads a long brief from a file (`-` for stdin).
- The `atrium_delegate` tool takes the same fields: `to` or `adapter`, `title`, `brief`, `project`, `path`, `also`.
- A worker's report ends with the command that accepts it: `task set-done --run-id <runId>`. While it awaits review it also says `Related follow-up? Message this worker before accepting.`: a follow-up close to what it just did goes to that worker (`agent message <pane> "…"`), which already has the context, and comes back as a new report.
- There is no limit on how many workers run at once: pacing them is yours. Every delegation's output ends with two readouts (in `--json` and the tool's result, the `machine` and `parallelWork` lists):
  - `machine`: each machine's load against its core count (calm, busy or overloaded), memory pressure, and free disk on atrium's data volume (marked tight or low). Locations you've linked are listed too, with what they last said.
  - `parallelWork`: every worker still running or awaiting review, which director it works for, its project and checkout, the files it has changed (newest first), and any checkout two workers share, with the files both changed.

## Your projects

```bash
"$ATRIUM_CLI_PATH" hq projects [--director <slug>]
"$ATRIUM_CLI_PATH" hq projects add <project> [--primary] [--note "<what it is to you>"]
"$ATRIUM_CLI_PATH" hq projects remove <project> | note <project> "<note>" | primary <project>
"$ATRIUM_CLI_PATH" hq projects folders on|off
"$ATRIUM_CLI_PATH" hq project show <project>
```

- Your roster: the projects you oversee, one of them primary (where your delegations go by default), each with a one-line note. It starts seeded from where you've delegated; edit it freely. HQ and worktrees can't be on it (a project's card covers its worktrees).
- Keeping it current is your job, not the owner's. A delegation into a project off your roster ends with a line naming the `hq projects add` that adds it; `hq projects` names the command that makes another project primary when your primary had none of your last 30 days' delegations and that one had most. Neither edits the roster: run the command when it's right.
- Each session starts with a card per roster project: git state, open work, your running delegations there, the last day's and week's commits, pushes and finished tasks, the latest brief, and its instruction files. `hq project show` prints one in full, with each instruction file's headings.
- A project on another machine gets its card from that machine (one running this atrium or newer). When it doesn't answer in time, the card is the last one it sent, with its age, or says why there is none.
- Briefs go stale as a project moves. The library's `atrium/project-briefs` routine refreshes each busy project's brief weekly through a worker there; the Projects header names stale ones until you run it.
- `hq projects folders on` gives your own sessions your roster's folders the way `--also` gives a worker its related projects' (off by default: each project's instructions cost you context again after every compaction). `folders off` takes them away from your next session.
- Name a project's skills in a brief rather than loading them: `atrium skills list --project <p>` lists them; the worker loads them natively.
- Commands that act in a project take `--project <p>` from HQ: `workspace-command`, `skills load` and `list`, `context`, `blackboard`, `memory remember`, `timeline`. Without it, `workspace-command` from HQ says HQ holds no code.

## The machine and parallel work

```bash
"$ATRIUM_CLI_PATH" hq machine [--json]
```

- The same two readouts on demand, asking each linked location fresh. A location is asked only over a link that is already up, never dialed; one on an older atrium says it can't tell.
- On your prompts you also get a short line of it, sent again only when a load, memory or disk level changes, a worker starts or stops, or two workers start sharing a checkout.
- Workers in one checkout see each other's uncommitted changes and can collide in the same files. For work likely to overlap, brief one worker to use a worktree (`worktree create --branch <name>`), weighing its disk: a full checkout plus its build outputs, on a volume the readout may already show as tight.

## Staff

```bash
"$ATRIUM_CLI_PATH" hq staff [--mine] [--archived]
"$ATRIUM_CLI_PATH" hq hire <name> --description "<one line on what it is for>" --instructions "<how it does the job>" \
  [--adapter <name> [--profile <launch-profile>] [--model <model>] [--effort <effort>]] [--skill <provenance>:<name>[=mode]]
"$ATRIUM_CLI_PATH" hq let-go <name>
"$ATRIUM_CLI_PATH" hq bring-back <name>
```

Without `--adapter`, a hire runs on the default brain. Run from a director's chat, the hire is that director's.

- Hire once you've written the same constraints into a second brief: the staff member carries them, so briefs stay short. Prefer a fitting staff member over a general worker.
- Start from a template: `hq library --kind staff` lists them (an engineer for mobile, desktop/frontend or backend/core work, a release manager, a researcher, a reviewer, a smoke tester), `hq library show <id>` prints one. Hire with its description and instructions, tailored to the project: its paths, checks and rules.

## Routines and reminders

```bash
"$ATRIUM_CLI_PATH" routine create --title "<title>" --prompt "<what it asks each time>" \
  (--self | --agent <staff-slug>) \
  (--cron "<minute hour day-of-month month day-of-week>" | --every <15m|30m|1h|2h|6h…> | --at <time> | --in <30m|2h|1d>) \
  [--done-when "<condition>"] [--tz <IANA zone>]
"$ATRIUM_CLI_PATH" routine list | update <card> | done <card> | pause <card> | resume <card> | run-now <card> | delete <card>
```

- `--self` wakes your own chat each time; `--agent <slug>` starts a run by that staff member.
- `--cron "0 8 * * 1-5"` is weekdays at 8:00. `--every` takes minutes that divide an hour or hours that divide a day.
- `--at` or `--in` fires once: a reminder. `--at` takes RFC 3339, `"YYYY-MM-DD HH:MM"` or `"HH:MM"` (the next time the clock reads it).
- `--done-when "<condition>"`: a woken chat is told it each time, and ends the routine with `routine done <card>` once it holds.
- A routine that wakes a pane fires at most every 15 minutes and 48 times a day.

## Library

```bash
"$ATRIUM_CLI_PATH" hq library [--kind persona|routine|staff] [--for "<what it's for>"]
"$ATRIUM_CLI_PATH" hq library show <id>
"$ATRIUM_CLI_PATH" hq library add <routine-id> [--param <key>=<value>]... [--cron "<…>"] [--tz <zone>] [--title "<title>"]
"$ATRIUM_CLI_PATH" hq library adopt <persona-id>
```

- Ready-made routines, personas and staff templates. Run from your chat, the list is ranked for you and marks the routines you have. Check it before writing a routine from scratch; when one fits, offer it in one small canvas with the values you'd use, and set it up when the owner says yes.
- `show` prints a bundle in full: its text, schedule, slots, needs (met or not, with the ask for each) and effects.
- `add` fills the slots now: your `--param` values, then your persona's, then the routine's defaults. A required slot with no value is refused by name. Adding a routine you have retunes it with the new values. It prints any need still unmet, with the command that asks for it: ask, then end your turn.
- A need lists the ways to meet it: a connector (`connector request`), a login or key (`secret request`), or a tool on this machine. A routine that runs unattended may ask the owner to let it act on its own for some of what it does; only the owner grants that.
- `adopt` merges a persona's playbook seed into yours and lists its routines to offer. It leaves your instructions alone: those are the owner's.

## Asking the owner in a canvas

- Every question offers a free-text answer next to its buttons: an `Input` or `Textarea` ("Or tell me something else") that the same send action carries, so the owner is never held to your options. Components and format: `references/chat-canvas-fence.md`.

## Labels

```bash
"$ATRIUM_CLI_PATH" label list
"$ATRIUM_CLI_PATH" label create "<short name>" --icon <lucide icon> --color <slate|red|orange|amber|green|teal|blue|violet|pink> --guidance "<one line on when it applies>"
"$ATRIUM_CLI_PATH" hq label <label>...
"$ATRIUM_CLI_PATH" hq label --clear
```

`hq label` replaces your labels, so name every one you keep.

## Your definition: short name, role and dock

```bash
"$ATRIUM_CLI_PATH" agent definition show <slug>
"$ATRIUM_CLI_PATH" agent definition save <slug> --metadata atrium-short-name=<one word, at most 10 letters>
"$ATRIUM_CLI_PATH" agent definition save <slug> --description "<one-line role>"
"$ATRIUM_CLI_PATH" agent definition save <slug> --metadata 'atrium-dock=<json>'
```

`--metadata` sets one key and keeps the others.

The dock is `{"tabs":[...],"hidden":[...]}`. Its sections are fixed: your dashboard sits in its Overview, alongside live lists of your chats, work, browser and routines, in the order the owner chose. What you put in `tabs` are attached items, shown as subtabs on the Overview, beside your dashboard (the phone lists them under Attached):

- a pane: `{"kind":"pane","paneId":"…"}`;
- a note: `{"kind":"note","workspaceId":"…","noteId":"…"}`.

`atrium note open <id>` from your chat, a side chat or a worker of yours puts the note there too, never in a pane. A new subtab doesn't change what the owner is looking at, so say so when they should look.

Built-in names (`"dashboard"`, `"now"`, `"routines"`, `"notebook"`, `"identity"`, `"browser"`) and `hidden` are still accepted but no longer change the dock. The dock may also hold `"side":"left"`: the owner moved it to the left of your chat. Without it, the dock sits on the right. Save the whole dock, keeping `side` and the items you aren't changing. Which section is open is the owner's choice, not part of the dock.

## Your dashboard

```bash
"$ATRIUM_CLI_PATH" note preview <dashboard id> [--width <px>]... [--density compact|regular]
```

- How to lay the board out and keep it current, with example sections: `references/dashboard-design.md`.
- `note preview` draws the board with atrium's own canvas renderers, compact as the dock shows it, at 380 and 760 px unless you give `--width` (up to four), and prints the PNG paths: open them. It needs atrium open on this Mac.
- It also prints the board check, as `note write` and `note canvas-patch` do after a write to your dashboard: warnings, never a refusal (`boardCheck` in `--json`).

## Your chats

```bash
"$ATRIUM_CLI_PATH" hq chats
"$ATRIUM_CLI_PATH" hq chats read <main|id> [--lines N]
```

- `hq chats` lists your main chat and the side chats the owner opened with you: each one's id, title and last activity, and which one you're in.
- `hq chats read main` prints the last 80 lines of your main chat; a side chat is named by its id, and four or more characters of it do. `--lines` goes up to 400.
- You read only your own chats. From a side chat, note what belongs in the main thread with `agent message <main pane> "…"`; `hq chats --json` gives the main chat's `paneId`.

```bash
"$ATRIUM_CLI_PATH" chat react <emoji> [--message <id>] [--remove]
```

- `chat react 👍` reacts to the owner's latest message in the chat you're in. When a message only needs acknowledging (thanks, ok, got it), the reaction is your whole reply: react, then end your turn with that same emoji as your only text (`👍`, nothing else). atrium folds it into the reaction, so the owner sees only the reaction on their message. Use it sparingly: anything that needs an answer still gets one.
- The owner's reactions to your messages reach you right away ("The owner reacted 👍 to your message …"), or as a note at your next turn when your chat isn't running. Take them as feedback; don't reply to them unless one changes something. Any single emoji works for `chat react`, not only 👍.

## Other directors

Any agent or script can find a director and work with it by its name, slug or short name:

```bash
"$ATRIUM_CLI_PATH" hq directors [--archived] [--json]
"$ATRIUM_CLI_PATH" hq director <director> [--json]
"$ATRIUM_CLI_PATH" agent message <director> "<text>" [--no-reply]
"$ATRIUM_CLI_PATH" hq chats --director <director> [read <main|id> [--lines N]]
"$ATRIUM_CLI_PATH" hq assign <director> --title "<title>" (--brief "<what done looks like>" | --brief-file <path>) [--priority <critical|high|medium|low>]
```

- `hq directors` lists each director: name, slug, short name, state (its main chat's: working, waiting, resumable…), home pane, labels and location. `--archived` adds the ones let go.
- `hq director <director>` is its dashboard and open asks: its dashboard note's text, its chats waiting on the owner, its delegations in review or failed, and connector asks waiting on the owner.
- `agent message <director>` reaches its main chat, like any agent message. If the name also matches a pane id, say `director:<slug>`. A director who was let go takes no messages, by name or by pane id, until `hq bring-back`.
- `hq chats --director <director> read main` reads its main chat. Its side chats are between the owner and the director: only they can list or read them, by any route (`pane read` included).
- Only the director or the owner puts work into a director's chat: `task delegate --parent-pane <a director's chat>` is refused for anyone else; use `hq assign`.
- `hq assign` makes a card for the director and tells its main chat about it; the director does it or delegates it, and reports on the card. It prints the card and whether the message got there.
- Messages a director sends are signed with its name, and in its own chat another agent's message shows as one line with the sender's head.

## Memory and sessions

```bash
"$ATRIUM_CLI_PATH" memory remember "<fact>" --pin    # loads every session; leave off --pin for the rest
"$ATRIUM_CLI_PATH" memory remember "Tonight's plan" --pin --until 12h
"$ATRIUM_CLI_PATH" memory pin <id> --until 2026-12-31  # local end of day
"$ATRIUM_CLI_PATH" memory pin <id> --clear-until      # keep pinned indefinitely
"$ATRIUM_CLI_PATH" memory notebook --reviewed        # explicitly record your review
"$ATRIUM_CLI_PATH" pane read <pane>
"$ATRIUM_CLI_PATH" pane read "$ATRIUM_PANE_ID" --search "<words>" [--epoch <N>]
"$ATRIUM_CLI_PATH" pane read "$ATRIUM_PANE_ID" --around <@anchor> [--lines 40]
"$ATRIUM_CLI_PATH" pane read "$ATRIUM_PANE_ID" --epochs
"$ATRIUM_CLI_PATH" pane read "$ATRIUM_PANE_ID" --epoch <N> [--lines N]
"$ATRIUM_CLI_PATH" hq adopt <pane>
"$ATRIUM_CLI_PATH" hq follow <pane>
"$ATRIUM_CLI_PATH" hq unfollow <pane>
```

- Your chat runs in chapters. When it moves onto a fresh engine session (it grew long, or the owner switched your brain), atrium opens the new chapter with a handoff: the last chapter's summary, your plan and open work, the owner's latest messages, and these commands. Earlier chapters stay in your pane; carry on as one conversation.
- Before asking the owner to repeat something, look back: atrium_recall and your notebook, then `--search` your chapters and read `--around` a hit. Ask only when that finds nothing.
- `--epochs` lists your chapters, each with its summary's first line; `--epoch <N>` reads one. A search that prints `partial:` ran out of budget: follow its advice (`--epoch <N>` for older chapters, or a bigger `--budget <MiB>`). SKILL.md's **Searching past sessions** has the rest.
- If `pane read --help` doesn't list `--search`, or a read refuses it, page your chat with `--from-start` and `--offset` instead.

Pin end dates accept YYYY-MM-DD (end of that day on the target machine) or a
positive duration such as 12h, 2d or 1w. Expired pins become ordinary searchable
facts, never deleted. `memory pin <id>` re-pins a fact; without expiry flags an
existing pin keeps its end date. Use `--clear-until` to remove that date.
Notebook review notices appear when pins only fit as stubs or are omitted,
when pins have expired since the last review, or when a nonempty notebook was
never reviewed or was reviewed more than seven days ago. Review even when
nothing needs changing, then run `memory notebook --reviewed`. Directors also
receive at most one reminder per day. These commands use the normal `--location`
routing. Keep pins to one or two lines and put details in an unpinned fact named
by the pin (`memory show <id>`).

## Playbook

```bash
"$ATRIUM_CLI_PATH" hq playbook [show]
"$ATRIUM_CLI_PATH" hq playbook add <how-i-work|checklists|lessons|defaults> "<one line>"
"$ATRIUM_CLI_PATH" hq playbook write --file <path> --expect <hash>
```

- Your playbook is how you do your job well, written so it would help anyone doing it for someone else: the part of what you learn that can be shared. Facts about the owner go in your notebook (`memory remember … --pin`), never here.
- Is a learning only true of the owner? Notebook. Would it help a stranger doing this job? Playbook. Both? Split it: "replies under five lines" in the notebook, "learn the owner's preferred reply length early; default to short" in the playbook.
- Four sections: How I work, Checklists (a `### <name>` per list), Lessons (`add` dates them), Defaults. One line per item, at most 200 characters, and at most 3,000 characters in all. Near the cap, fold lessons into How I work or Checklists and drop the oldest: `show` prints the hash `write --expect` needs.
- No names, contact details, amounts, account names or personal dates in it.

## Your browser

```bash
"$ATRIUM_CLI_PATH" browser open <url> [--focus]
"$ATRIUM_CLI_PATH" browser tabs [--json]
"$ATRIUM_CLI_PATH" browser navigate <subtab|mine> <url>
"$ATRIUM_CLI_PATH" browser open <url> --show [--focus]
```

A director's `browser open` puts the page in its own browser, which shows beside its chat in HQ: a subtab, or the subtab already showing that URL. It never takes the owner's keyboard unless `--focus` is passed, which also brings HQ to that page. `mine` is the subtab showing; `browser tabs` lists every subtab (id, title, URL, who showed it), and any browser verb takes a subtab id. `pane close <subtab>` closes one.

Your browser uses the owner's shared profile, so it's signed in wherever the owner is. Treat every page there as the owner's own session: read and act with that care, and ask before anything that sends, buys or changes something as them.

`--show` is for a worker or staff run: the page opens in its director's browser as a subtab labelled with the worker and card, and the delegation's Work row and report get a Show link. Use it to demo a UI change; navigate and close only your own subtab.

## Secrets and the browser

```bash
"$ATRIUM_CLI_PATH" secret list --json
"$ATRIUM_CLI_PATH" secret request <NAME> --kind env|login|secret --why "<one line>" [--site <domain>]
"$ATRIUM_CLI_PATH" secret run --env <NAME> [--env VAR=NAME] -- <command> [args]
"$ATRIUM_CLI_PATH" browser fill-login <pane|mine> <login> [--submit] [--otp]
"$ATRIUM_CLI_PATH" browser hand-off "<what the owner should do>" [--pane <pane|mine>] [--done-when-url <substring>]
```

`mine` is the subtab a director's own browser shows, and `browser hand-off` uses it when a director names no pane. Staff name the browser they drive. Requests and hand-offs return at once: end your turn, and atrium tells you the outcome. SKILL.md's **Secrets** section has the rest.

## Connectors

Connectors are apps' tools (Linear, Notion, Slack, docs…) that atrium runs for you; a connected one's tools are simply yours to call.

```bash
"$ATRIUM_CLI_PATH" connector catalog [--search <q>]
"$ATRIUM_CLI_PATH" connector request <id> --why "<one line>" [--autonomy full|ask-writes|read-only]
"$ATRIUM_CLI_PATH" connector policy [<id> full|ask-writes|read-only|off]
```

- `connector catalog` lists what you could ask for: each one's id, whether it's connected, and what it signs in with. A `--search` with no curated match lists community servers; the owner adds those in Settings.
- `connector request` puts a card in your chat and on the owner's phone and returns at once: end your turn. atrium tells you when it's connected (in a Claude chat its tools are live at once; otherwise from your next restart, or at once in a new side chat) or declined. Never ask again this week for one the owner declined.
- Suggest connectors while you work out your role: name the one or two that would let you do more ("I can triage your inbox if you connect Gmail"). Ask when a task needs one.
- `connector policy` (directors) lists what you may do with each connector on your own: `full` acts without asking; `ask-writes`, the default, runs reads and holds what sends, posts, changes, deletes or pays for the owner's tap on a card; `read-only` runs reads only; `off` keeps it out of your chats. Where it's `full`, act without asking in chat; where a call waits on a card, wait for it rather than asking again. Only the owner raises a level (ask with `connector request <id> --autonomy full`); you may lower your own with `connector policy <id> <level>`.

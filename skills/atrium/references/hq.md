# atrium HQ: commands for directors and staff

atrium's director and staff rules say what to do and name the command for it. This is the reference for those commands' flags and formats. `--help` on any of them shows the full surface.

## Delegating

```bash
"$ATRIUM_CLI_PATH" task delegate --title "<title>" --brief "<goal, context, constraints, what done looks like>" (--to <staff-slug> | --adapter <name>) [--workspace <project>]
```

- `--to <slug>` hands it to a staff member (`hq staff` lists them). For a general worker, leave out `--to` and pass `--adapter <name>`: the CLI it runs on, e.g. `claude-code`. A name that isn't a staff member's is refused.
- `--workspace <name>`: work that touches code names its project (`workspace list`).
- `--brief-file <path>` reads a long brief from a file (`-` for stdin).
- The `atrium_delegate` tool takes the same fields: `to` or `adapter`, `title`, `brief`, `workspace`.
- A worker's report ends with the command that accepts it: `task set-done --run-id <runId>`.

## Staff

```bash
"$ATRIUM_CLI_PATH" hq staff [--mine] [--archived]
"$ATRIUM_CLI_PATH" hq hire <name> --description "<one line on what it is for>" --instructions "<how it does the job>" \
  [--adapter <name> [--profile <launch-profile>] [--model <model>] [--effort <effort>]] [--skill <provenance>:<name>[=mode]]
"$ATRIUM_CLI_PATH" hq let-go <name>
"$ATRIUM_CLI_PATH" hq bring-back <name>
```

Without `--adapter`, a hire runs on the default brain. Run from a director's chat, the hire is that director's.

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

- Ready-made routines and personas. Run from your chat, the list is ranked for you and marks the routines you have. Check it before writing a routine from scratch; when one fits, offer it in one small canvas with the values you'd use, and set it up when the owner says yes.
- `show` prints a bundle in full: its text, schedule, slots, needs (met or not, with the ask for each) and effects.
- `add` fills the slots now: your `--param` values, then your persona's, then the routine's defaults. A required slot with no value is refused by name. Adding a routine you have retunes it with the new values. It prints any need still unmet, with the command that asks for it: ask, then end your turn.
- A need lists the ways to meet it: a connector (`connector request`), a login or key (`secret request`), or a tool on this machine. A routine that runs unattended may ask the owner to let it act on its own for some of what it does; only the owner grants that.
- `adopt` merges a persona's playbook seed into yours and lists its routines to offer. It leaves your instructions alone: those are the owner's.

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

## Memory and sessions

```bash
"$ATRIUM_CLI_PATH" memory remember "<fact>" --pin    # loads every session; leave off --pin for the rest
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

## Secrets and the browser

```bash
"$ATRIUM_CLI_PATH" secret list --json
"$ATRIUM_CLI_PATH" secret request <NAME> --kind env|login|secret --why "<one line>" [--site <domain>]
"$ATRIUM_CLI_PATH" secret run --env <NAME> [--env VAR=NAME] -- <command> [args]
"$ATRIUM_CLI_PATH" browser fill-login <pane|mine> <login> [--submit] [--otp]
"$ATRIUM_CLI_PATH" browser hand-off "<what the owner should do>" [--pane <pane|mine>] [--done-when-url <substring>]
```

`mine` is a director's own browser, and `browser hand-off` uses it when a director names no pane. Staff name the browser they drive. Requests and hand-offs return at once: end your turn, and atrium tells you the outcome. SKILL.md's **Secrets** section has the rest.

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

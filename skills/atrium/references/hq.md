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

The dock is `{"tabs":[...],"hidden":[...]}`. Its sections are fixed: your dashboard sits in its Overview, alongside live lists of your chats, work, browser, routines and attached items, in the order the owner chose. What you put in `tabs` are attached items, listed in the Overview:

- a pane: `{"kind":"pane","paneId":"…"}`;
- a note: `{"kind":"note","workspaceId":"…","noteId":"…"}`.

Built-in names (`"dashboard"`, `"now"`, `"routines"`, `"notebook"`, `"identity"`, `"browser"`) and `hidden` are still accepted but no longer change the dock. Save the whole dock, keeping the items you aren't changing. Which section is open is the owner's choice, not part of the dock.

## Your chats

```bash
"$ATRIUM_CLI_PATH" hq chats
"$ATRIUM_CLI_PATH" hq chats read <main|id> [--lines N]
```

- `hq chats` lists your main chat and the side chats the owner opened with you: each one's id, title and last activity, and which one you're in.
- `hq chats read main` prints the last 80 lines of your main chat; a side chat is named by its id, and four or more characters of it do. `--lines` goes up to 400.
- You read only your own chats. From a side chat, note what belongs in the main thread with `agent message <main pane> "…"`; `hq chats --json` gives the main chat's `paneId`.

## Memory and sessions

```bash
"$ATRIUM_CLI_PATH" memory remember "<fact>" --pin    # loads every session; leave off --pin for the rest
"$ATRIUM_CLI_PATH" pane read <pane>
"$ATRIUM_CLI_PATH" hq adopt <pane>
"$ATRIUM_CLI_PATH" hq follow <pane>
"$ATRIUM_CLI_PATH" hq unfollow <pane>
```

## Secrets and the browser

```bash
"$ATRIUM_CLI_PATH" secret list --json
"$ATRIUM_CLI_PATH" secret request <NAME> --kind env|login|secret --why "<one line>" [--site <domain>]
"$ATRIUM_CLI_PATH" secret run --env <NAME> [--env VAR=NAME] -- <command> [args]
"$ATRIUM_CLI_PATH" browser fill-login <pane|mine> <login> [--submit] [--otp]
"$ATRIUM_CLI_PATH" browser hand-off "<what the owner should do>" [--pane <pane|mine>] [--done-when-url <substring>]
```

`mine` is a director's own browser, and `browser hand-off` uses it when a director names no pane. Staff name the browser they drive. Requests and hand-offs return at once: end your turn, and atrium tells you the outcome. SKILL.md's **Secrets** section has the rest.

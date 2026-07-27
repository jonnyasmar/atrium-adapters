---
name: atrium-bug-report
description: "Investigate an atrium problem from the local artifacts on this machine, determine a root cause where the evidence supports one, and file a curated issue on the public tracker jonnyasmar/atrium-issues. Use when the user reports that atrium misbehaved, when a seeded prompt contains an <atrium-bug-report> block, or when the user asks to file/report an atrium bug. Covers instance resolution, log correlation, benign-noise filtering, redaction, and the approval gate before posting."
version: "0.1.0"
---

# atrium — bug report

You are filing a bug on **atrium** to the public tracker `jonnyasmar/atrium-issues`.

**The investigation is the product.** A maintainer reading your issue must be able to act on it without asking for more data, and without a single attachment. There are no ZIPs, no gists, no log dumps — you read the artifacts, you decide what is load-bearing, you quote only that, and you say what you think actually broke.

Three rules that outrank everything else below:

1. **Never post without showing the user the literal final body and getting explicit approval.** Not a summary of it — the text. If they say no, stop. Do not re-draft and post anyway.
2. **A confidently wrong root cause in a public tracker is worse than none.** "Undetermined — here is what I ruled out" is a good issue.
3. **Read-only while investigating.** Reading logs, `--json` list commands and `pane read` are free. Anything that mutates the workspace changes the state you are diagnosing. See *Read-only CLI* below for the boundary.

**Demonstrations are not reports.** If you are walking this skill through rather than investigating something that actually happened — a demo, a dry run, "show me what this does" — open your output with a plain `**DEMO — illustrative, not a real investigation.**` and keep every value in it obviously synthetic. A demo stops at the draft: the posting path in Step 8 is closed to it, with or without approval. A demo and a real report look identical once written, which is exactly why the label has to be on the front of it.

---

## What you were given

A seeded launch supplies this block. Everything in it is authoritative — do not re-derive it.

```
<atrium-bug-report>
reportedAt: <ISO8601 UTC>
dataDir: <absolute atrium data dir>
instance: <data dir basename>
version: <app version>
channel: <stable|dev|unknown>
os: <os name and version>
</atrium-bug-report>

User's report:
<text, or "(none provided — ask the user what went wrong)">
```

**If there is no block, you were invoked cold** — from a plain terminal, quite possibly because atrium itself is wedged. Resolve everything yourself (Step 0) and ask the user what happened. Everything below works either way.

---

## Step 0 — Resolve the instance, before you read anything

One machine can host several atrium installs, each with its own complete data dir. Reading the wrong one gives you a log that is quiet at exactly the moment the user says the app was busy — and you will misread that silence as evidence. **Resolve first, verify, then read.**

```bash
echo "${ATRIUM_DATA_DIR:-unset}"        # authoritative when set — atrium injects it into every pane shell
ls -d ~/.atrium ~/.atrium-dev* 2>/dev/null
```

- The seed block's `dataDir` wins. Otherwise `$ATRIUM_DATA_DIR`. Otherwise resolve from the listing.
- `~/.atrium` is the **installed app**. That is what a normal user has, and usually the only one.
- `~/.atrium-dev` and `~/.atrium-dev-<something>` are **developer builds** — one per git worktree. If these exist the user builds atrium from source, and you must not assume the bug is in the shipped app.

Confirm you picked right before spending effort:

```bash
D=<resolved data dir>
ls "$D/logs" "$D/ipc"                                   # both must exist; if not, wrong dir
cat "$D/ipc/"*.lock 2>/dev/null                         # channel + live daemon identity
ls -lt "$D/logs" | head -5                              # is this instance's log fresh?
```

`ipc/` names the channel: `stable.lock` / `stable.sock` → the installed app; `dev.lock` / `dev.sock` → a dev build. The lock file is JSON — `pid`, `executable`, and `runtimeFingerprint` identify the daemon that owns this data dir. If `logs/`'s newest file has not been touched since well before the reported time, **you are on the wrong instance** — go back and pick another.

Two or more instances present: state which one you investigated in the issue, and say so out loud to the user before you start.

### The CLI for this instance

```bash
CLI="${ATRIUM_CLI_PATH:-$D/bin/atrium}"     # dev instances name it bin/atrium-dev
"$CLI" version --json
```

`version --json` returns `{"app": "connected"|..., "channel": "...", "cli": "..."}`. **`app` is itself evidence.** If the user says the window is on screen but `app` is not `connected`, the UI is up while the IPC socket is dead — that is not a failed command, that is the bug. Record it and move on; do not retry in a loop. Give any app-dependent command a short timeout (`timeout 10 "$CLI" …`) so a wedged runtime does not wedge you.

---

## Step 1 — Fix the time anchor

`reportedAt` is when the user pressed the button, **not when the bug happened.** They may have watched it for a minute, or hit it the next morning.

Establish `T` — the moment of the failure:

- Obvious in the logs (a crash, a restart, a burst) → use that.
- Otherwise ask, as one of your three questions: *"Roughly when did this happen — and had you just updated, restarted, or opened something new?"*
- No answer available → anchor on `reportedAt` and widen the window to ±10 minutes, and say in the issue that the window is approximate.

Then convert `T` into each file's time base, because **these artifacts run on three different clocks**:

| File | Clock | Format, with a **synthetic** example |
|---|---|---|
| `logs/runtime.<date>.log` | **UTC**, ISO8601 with `Z` | `YYYY-MM-DDTHH:MM:SS.ffffffZ` — e.g. `2000-01-01T12:00:00.000000Z` |
| `logs/app.<date>.log` | **UTC**, ISO8601 with `Z` | `YYYY-MM-DDTHH:MM:SS.ffffffZ` — e.g. `2000-01-01T12:00:00.000000Z` |
| `logs/daemon-signals.log` | **UTC**, ISO8601 with `+00:00` | `YYYY-MM-DDTHH:MM:SS.ffffff+00:00` — e.g. `2000-01-01T12:00:00.000000+00:00` |
| `logs/cef.log` | **local time**, `MMDD/HHMMSS.uuuuuu` | `MMDD/HHMMSS.ffffff` — e.g. `0101/080000.000000` (= the `12:00:00` UTC above, at UTC-4) |
| `logs/webview-errors.ndjson` | ISO8601 `ts` field | per record |
| `~/Library/Logs/DiagnosticReports/*.ips` | **local time with offset** | `YYYY-MM-DD HH:MM:SS.ss ±HHMM` — e.g. `2000-01-01 08:00:00.00 -0400` |
| `logs/atriumd.stderr.log` | **no timestamps at all** | see below |

The example column is **synthetic** — a made-up clock chosen to be unmistakable. It teaches the shape and nothing else. **Nothing in this skill is data**: every timestamp, id, pid and log line below is an illustration, so none of them may be quoted as if you read it in a file.

Getting this wrong by a timezone offset makes the CEF log look like it has nothing to say. Compute the offset once (`date +%z`) and write both forms down.

`runtime.<date>.log` rotates on the **UTC** date, so west of UTC an evening incident lands in the *next* day's file. When the expected file is missing or ends early, check the neighbouring day before concluding the app was idle.

---

## Step 2 — Build one chronological timeline

Grep every log for `T ± 60s`, then merge into a single ordered list. **Cross-file correlation is the whole job** — a human triager does it automatically and an agent skips it unless told. A CEF renderer crash three seconds before a "the app went gray" report is the answer; neither file says so alone.

```bash
D=<data dir>; L="$D/logs"
DAY=<YYYY-MM-DD>                     # UTC date of T
UTC=<HH:M>                           # UTC hour + tens-of-minutes of T
LOC=<MMDD/HH+tens>                   # local time base, for cef.log

grep -aE "^${DAY}T${UTC}" "$L/runtime.$DAY.log"
grep -aE "^${DAY}T${UTC}" "$L/app.$DAY.log" 2>/dev/null   # newer builds only
grep -aE "^${DAY}T${UTC}" "$L/daemon-signals.log"
grep -aE "\]${LOC}"        "$L/cef.log"
grep -a  "\"ts\":\"${DAY}T${UTC}" "$L/webview-errors.ndjson" 2>/dev/null
ls -t ~/Library/Logs/DiagnosticReports/ | grep -iE 'atrium'   # crash reports, newest first
```

Widen to the full hour if the minute window is empty. Then narrow the timeline down to the lines that changed your mind about something — a merged timeline of 200 lines is not a timeline.

### Reading `atriumd.stderr.log` (the daemon), which has no timestamps

This is the single most useful and most awkward artifact. It is the **background daemon** — the prime suspect for anything about restore, session lifecycle, activity/fleet state, scheduling, chat sidecars, and indexing. It is also large (tens of MB), never rotated within a run, and its `[HOOK]` lines are truncated mid-JSON by the logger. It carries no timestamps, so:

- **Never read it whole.** `tail -n 5000` for "what just happened", `grep -a` for a specific id.
- **Correlate by identity, not by time.** Pane ids, session keys and run ids appear in both this file and `runtime.<date>.log`. Grep the daemon log for the id, then find the same id in the timestamped runtime log to place it.
- **Bound the region with anchors.** `[fleet-hydrate] seeded N warm`, `[harness_scan boot]` and `[chat-runtime-reaper]` fire at daemon start, so the last occurrence marks the start of the current run. `[pty-reaper]` fires periodically and slices the file into rough intervals.
- **`grep -n` and use line numbers as your ordering axis** when you need to say "this happened before that".

```bash
tail -5000 "$L/atriumd.stderr.log" | grep -av '^\[HOOK\]'      # signal, minus 90% of the volume
grep -an "<pane-or-session-id>" "$L/atriumd.stderr.log" | tail -40
grep -an '^\[fleet-hydrate\] seeded' "$L/atriumd.stderr.log" | tail -3   # where this run began
```

---

## Step 3 — Hypotheses, then evidence for and against

Pick the matching class from **Symptom → hypothesis** below. For each candidate, write down *before you look*: what would confirm it, and what would rule it out. Then go find both. An agent that only looks for confirmation always finds it.

Filter every alarming line through the **Benign noise** table first. The loudest `ERROR` in an atrium log is very often routine — reporting it as the root cause is the default failure mode of this whole exercise.

Useful calibration, measured on a live install: `runtime.<date>.log` in normal operation is **INFO and WARN only** — a typical busy day logs ~15,000 INFO lines, ~70 WARN, and **zero ERROR**. So an `ERROR` there is a real signal *if* it is not one of the two known-benign ones. `atriumd.stderr.log`, by contrast, is unleveled — the presence of the word "failed" means nothing on its own.

---

## Step 4 — Interview: at most three questions

Ask **at most 3**, and **never one the artifacts already answer.** You already have the version, channel, OS, adapter list, room and pane counts, workspace layout, and everything in the logs. Asking for them wastes the user's patience and tells them you did not look.

Spend the questions on things that split the hypotheses that are still standing:

- *"Roughly when did it happen — and had you just updated, restarted, or opened something new?"* (anchors `T`; splits update/restart regressions from steady-state ones)
- *"Did it affect one pane or room, or the whole app?"* (splits pane-local from process-wide)
- *"Does it happen again if you try it, and what's the shortest way to get there?"* (splits a race from a deterministic defect)
- Targeted alternatives when the logs already narrowed it: *"Was the pane you were clicking sitting on top of a browser pane?"*, *"Do you have a wallpaper set?"*, *"Was a second atrium window or a dev build running?"*

If the user gave no report text at all, your first question is simply what went wrong — that one is free and does not count against the budget.

---

## Step 5 — Write the local evidence file

Before drafting the issue, write your **full working record** to:

```
<dataDir>/diagnostics/report-<YYYYMMDD-HHMMSSZ>.md
```

Everything: every log line you read, every command you ran and its output, every hypothesis with the evidence for and against, what you ruled out and why, and the questions and answers. This file is **local only, never posted, and not redacted** — full fidelity is the point.

It is the safety valve for a design with no attachments: when the diagnosis does not hold up, a maintainer can ask the user for this file. Because it is unredacted, tell the user that — they should skim it before sharing it with anyone.

The issue body's last line points at this path. That is the only place it appears publicly.

---

## Step 6 — Check for a duplicate

```bash
gh issue list --repo jonnyasmar/atrium-issues --state all --limit 20 \
  --search "<2-4 distinctive words from the symptom>"
gh issue list --repo jonnyasmar/atrium-issues --state all --limit 20 --search "in:title <keyword>"
```

Search the **symptom**, not your root cause — the existing report was written by someone who did not know the cause either. Try two or three phrasings.

If something close exists: show it to the user and offer to **add a comment** with your findings instead of opening a duplicate. A well-evidenced comment on an open issue is worth more than a second issue. A closed issue that matches is still worth mentioning — if it is marked `fixed` and the user is on a newer version, that is a regression and worth its own issue, linked to the old one.

---

## Step 7 — Draft the issue

The body is **self-contained and tight**. Target under ~8 KB so the no-`gh` fallback URL works.

Build these sections **once** and use them for either posting path — they map one-to-one onto the field ids of the repo's `bug.yml` issue form:

| Section | `bug.yml` field id |
|---|---|
| `## Environment` (composed) | `version`, `channel`, `os` — three separate fields in the form |
| area label choice | `area` |
| `## Summary` | `summary` |
| `## Steps / trigger` | `steps` |
| `## Expected` | `expected` |
| `## Observed` | `observed` |
| `## Root cause` | `root-cause` |
| `## Evidence` | `evidence` |
| `## Ruled out` | `ruled-out` |
| the trailing local-path line | `evidence-file` |

```markdown
## Summary
<2-4 sentences: what the user was doing, what happened, and — if you found one — the cause.>

## Environment
- atrium v<version> (<channel>), <os>
- <anything else the artifacts showed that matters: adapters in play, workspace scale, dev build vs installed>

## Steps / trigger
<What preceded it. "Unknown — noticed after the fact" is an acceptable and honest value.>

## Expected
<one or two lines>

## Observed
<what actually happened, including anything the user saw that the logs do not show>

## Root cause
<Your conclusion and the reasoning chain — or the Undetermined form below.>

## Evidence

<details><summary>runtime.log around <time></summary>

```
<the lines that are load-bearing — not the surrounding context>
```
</details>

<details><summary>atriumd.stderr.log (daemon)</summary>

```
<…>
```
</details>

## Ruled out
- <hypothesis> — <the specific evidence that killed it>

---
Local evidence file (not attached, on the reporter's machine): `~/<instance>/diagnostics/report-<ts>.md`
```

**Title:** `<one-line symptom> (v<version>)` — lead with what the user experienced, not your theory. Illustrative shape only: `Terminal pane stops rendering after a room switch (v<version>)`.

**Evidence budget: 20–40 log lines total.** Every quoted line must be one you would point at while explaining the bug. `<details>` blocks keep them from drowning the body. If a section would be empty, drop the heading.

**When you did not find a root cause**, use exactly this shape — it is a good outcome, not a failure:

```markdown
## Root cause

**Undetermined.** Ruled out:

- <hypothesis> — <evidence against>
- <hypothesis> — <evidence against>

Strongest remaining lead: <what>, unconfirmed because <what evidence is missing and why it isn't obtainable locally>.
```

### Redact as you quote — never scrub at the end

Redact **at the moment you copy a line into the draft**. Scrubbing a finished draft is exactly where misses happen, because by then you are reading for sense, not for secrets.

| Thing | Becomes |
|---|---|
| `/Users/<name>/…`, `/home/<name>/…` | `~/…` |
| the OS username anywhere else | `<user>` |
| project / repo / branch / worktree names | `<project>`, `<repo>`, `<branch>` — unless the user says the repo is public |
| email addresses | `<email>` |
| anything token-shaped (20+ chars, mixed case + digits, high entropy) | `<redacted>` |
| `sk-…`, `ghp_…`, `gho_…`, `github_pat_…`, `xoxb-…`, `AKIA…`, `Bearer …` | `<redacted>` |
| `*_API_KEY=…`, `--api-key <v>`, `-e KEY=<v>` in adapter command lines | keep the flag/var **name**, redact the value |
| UUIDs (pane, room, session, run) | keep the **first 8 chars only** — they correlate lines within the issue and mean nothing off-machine |
| adapter session ids, transcript paths, prompt or conversation text | **omit entirely** — describe rather than quote |

Adapter command lines are the one place API keys reliably surface (`adapter list`, launch-profile `cliArgs`/`env`, `pane list`). Check them specifically.

This is **best effort, and the user's approval of the literal body is the real backstop.** Say that when you present the draft.

---

## Step 8 — Approval, then post

Show the user the **complete final body, verbatim**, plus the title and the labels you intend to apply. Then ask. Not "shall I file this?" after a summary — the actual text.

- If they say no: **stop.** Ask what to change, or drop it. Never post a revised version without a fresh approval.
- If they want edits: revise, show the full body again, ask again.

**Preferred — `gh`:**

```bash
gh auth status                       # must be authenticated to jonnyasmar/atrium-issues

gh issue create --repo jonnyasmar/atrium-issues \
  --title "<title>" --body-file /tmp/atrium-issue.md

# Labels separately and best-effort — a label that doesn't exist yet fails `create` outright.
N=<issue number from the URL gh printed>
for L in bug source:in-app "area:<subsystem>" "version:<x.y.z>"; do
  gh issue edit "$N" --repo jonnyasmar/atrium-issues --add-label "$L" 2>/dev/null || true
done
```

`gh issue create` bypasses the issue form — that is fine and expected, because your body already carries the same sections.

**Fallback — no `gh`, or not authenticated.** Prefill the web form and let the user submit it themselves. Open it in an atrium browser pane (the `atrium` skill covers browser panes; `pane create --type browser --url "<url>"`), or just hand them the URL if atrium is the thing that is broken.

```
https://github.com/jonnyasmar/atrium-issues/issues/new?template=bug.yml&labels=bug,source:in-app
  &title=<urlencoded>&version=<…>&channel=<…>&os=<…>&area=<…>
  &summary=<…>&steps=<…>&expected=<…>&observed=<…>&root-cause=<…>
  &evidence=<…>&ruled-out=<…>&evidence-file=<…>
```

The query parameter names are the `bug.yml` field ids. URL-encode each value. GitHub truncates very long URLs — this is why the body is budgeted at ~8 KB. If it still will not fit, trim the `evidence` block first (it is the only section with a local copy in the evidence file) and note in the body that evidence was trimmed for length.

Either way: **the user presses submit or you press it with their explicit yes. There is no third option.**

---

# Reference

## Artifact map

Everything is under the resolved data dir unless noted. Presence varies — a fresh install has fewer files, and a user who has never opened a browser pane has no `cef.log`.

| Artifact | What it is | Answers | Does *not* answer |
|---|---|---|---|
| `logs/runtime.<YYYY-MM-DD>.log` | Main process, daily rotation, `tracing` format, UTC | App lifecycle, boot hydration, persistence, PTY/websocket, adapter script calls, pane/room ops | Anything the daemon does alone; anything in the frontend |
| `logs/app.<YYYY-MM-DD>.log` | The desktop shell process (`atrium-desktop`), daily rotation, same `tracing` format. **Newer builds only** — absent on older installs, which is not itself a bug | Shell-side startup, window/CEF hosting, updater and native chrome — the half that never reached `runtime.log` | The daemon; the frontend |
| `logs/atriumd.stderr.log` | The background daemon, unleveled `eprintln!`, **no timestamps**, huge, `[HOOK]`-dominated | Restore/session lifecycle, fleet & activity state, scheduler, chat sidecars, FTS/vault indexing, reapers | *When* anything happened |
| `logs/cef.log` | Chromium/CEF — **browser panes only**, local time | Browser pane navigation, renderer/GPU errors, media, codec issues | Anything outside a browser pane |
| `logs/daemon-signals.log` | One line per daemon lifecycle signal, UTC, small — **read it whole** | Clean quits vs. forced kills; update handoffs | Why the daemon was slow to exit |
| `logs/webview-errors.ndjson` (+ `.1.ndjson` when rotated at 2 MB) | Frontend JS errors, one JSON object per line | Which React subtree threw, which IPC command failed | Anything the frontend caught and handled |
| `~/Library/Logs/DiagnosticReports/*.ips` (macOS, **outside the data dir**) | OS crash reports | Hard crashes, panics, signals, faulting stack | Hangs that never crashed |
| `diagnostics/` | Perf `.ndjson` captures (only when diagnostics are enabled) and older support bundles | Frame/IPC timings for a perf report | Anything, if `config.json`'s `diagnostics.enabled` is `false` |
| `chat/journals/<sessionKey>.jsonl` | Durable per-chat-pane journal | What an agent-chat pane actually received and emitted | The adapter's own internal transcript |
| `config.json` | User settings | `updates.channel`, `diagnostics.enabled`, keybindings, adapter command overrides | |
| `state.json`, `workspaces/<id>/workspace.json` | Persisted app + per-workspace layout | Whether a layout was actually saved | |
| `ipc/<channel>.lock`, `.sock` | Live daemon identity and the socket | Which daemon owns this data dir, and its pid | |
| `adapter-registry/`, `adapters/` | Installed adapter definitions | Adapter version/schema drift | |
| `captures/` | QA Capture recordings (`CAP-N`) | A video of the failure, if one exists — `"$CLI" capture list` | |

### `webview-errors.ndjson` fields

`ts`, `kind`, `message`, `stack`, `context`, `detail`.

`kind` is one of:

| `kind` | Means |
|---|---|
| `react-root` | The **whole UI** crashed — the app is blank or gray from the frontend's side, not the backend's |
| `react-pane` | One pane's error boundary caught it — that pane is broken, the rest of the app is fine |
| `react-pane-header` | A pane header crashed; pane content usually survives |
| `window-error` | Uncaught JS error |
| `unhandled-rejection` | A promise rejected with no handler — often a failed IPC call one layer up |
| `ipc-failure` | A Tauri command failed; `detail.command` names it, and that name usually names the subsystem |

```bash
tail -50 "$L/webview-errors.ndjson" | jq -c '{ts,kind,message,cmd:.detail.command}'
```

### Reading a `.ips` crash report

Two JSON documents concatenated: line 1 is a header (`app_version`, `os_version`, `timestamp`), the rest is the body.

```bash
ls -t ~/Library/Logs/DiagnosticReports/ | grep -iE 'atrium'
```

- `atrium-desktop-*.ips` — the main app process.
- `atrium Helper*.ips` (bundle id `com.skybot.atrium.helper`) — a **CEF child process**, i.e. a browser pane. A helper crash with no main-app crash means a browser pane died and the app itself was fine.
- `atriumd-*.ips` — the daemon.

```bash
python3 - "<file.ips>" <<'EOF'
import json,sys
body=json.loads(open(sys.argv[1]).read().split('\n',1)[1])
print(body.get("exception"), body.get("termination"), body.get("asi"))
th=body["threads"][body["faultingThread"]]
for f in th["frames"][:15]:
    print(" ", body["usedImages"][f["imageIndex"]].get("name"), f.get("symbol",""))
EOF
```

Interpreting it:

- `EXC_CRASH` + `SIGABRT` + `"asi": {"libsystem_c.dylib": ["abort() called"]}` with frames containing `rust_begin_unwind` / `panic_with_hook` → **a Rust panic**. The frame *below* the panic machinery names the module that panicked — that is your root cause. Illustrative reading (not data from any machine): a faulting stack ending in `tao…app_delegate…did_finish_launching` would be a panic during window creation at launch, i.e. the app never got a window up.
- `EXC_BAD_ACCESS` → a native segfault; in an `atrium Helper` report that is a CEF renderer crash.
- `EXC_RESOURCE` → an OS resource limit (memory/CPU), not a logic bug.
- A report whose `procPath` is under `/Users/USER/*/atrium-desktop` with `parentProc: node` is a **dev build**, not the shipped app — do not file it as a release bug without saying so.

## Read-only CLI

Use `--json` on everything you parse. Prefix with `timeout 10` when the app may be wedged.

| Command | Gives you |
|---|---|
| `"$CLI" version --json` | cli version, channel, and whether the app is `connected` |
| `"$CLI" context --json` | your workspace / room / pane / adapter |
| `"$CLI" pane list --json` | every pane: id, type, adapter, workspace, room — the live shape of the workspace |
| `"$CLI" room list --json` | rooms, wings, pane counts |
| `"$CLI" adapter list --json` | installed adapters, resolved binary path, ready/not-ready status |
| `"$CLI" agent list --json` | live agent panes |
| `"$CLI" workspace-command list --json` | run-commands and their lifecycle state |
| `"$CLI" task list --json`, `"$CLI" run list --json` | task cards and runs (for scheduler / task-launch reports) |
| `"$CLI" launch-profile list --json` | launch profiles — check here when a card references a missing profile |
| `"$CLI" pane read <id> --lines 200` | **what the user actually sees** in a terminal pane, rendered. The only way to capture a wedged or garbled terminal |
| `"$CLI" capture list --json` / `capture show CAP-N` | an existing recording of the failure |

**Never, while investigating:** `pane create/write/close/focus/resize`, `agent message/dismiss/wake/stop`, `room switch/close/rename`, `workspace-command start/stop/restart`, `task create/update`, `config set`, `browser <anything>`. The single exception is opening a browser pane in Step 8 to post — after the user approved it.

Run `"$CLI" <command> --help` for exact flags rather than guessing.

## Benign noise

These look alarming and are routine. **Do not report one as a root cause** unless the symptom specifically matches the narrow case named in the last column.

Marked **[confirmed]** where observed at volume on a live install; **[inferred]** where the reading is deduced from the message and surrounding context rather than verified.

The lines in these tables — and in **Symptom → hypothesis** below — are **match patterns, not evidence**. `<id>`, `<path>` and `N` are placeholders, and the real line carries a timestamp, a level and a module path that none of these rows show. Grep for the pattern, then quote the line the file actually gives you.

### `runtime.<date>.log`

| Line | Reading | Only relevant if |
|---|---|---|
| `WARN …hooks: Unknown hook event type: command-start` / `command-end` | **[confirmed]** An adapter emits lifecycle events atrium doesn't route. Constant background. | never |
| `WARN …workspace: Failed to kill PTY <id> during workspace deletion: PTY not found for pane` | **[confirmed]** Teardown ordering — the PTY was already gone. | never |
| `WARN …script_adapter: adapter static file for method '<m>' does not match the bundled schema (continuing anyway)` | **[confirmed]** Adapter/app schema drift. `(continuing anyway)` is the tell — the value is used regardless. | the symptom is a **missing or wrong option in the launcher** (model, effort). Then the offending JSON in the message *is* the answer. |
| `WARN …panes: resize_pane: pane <id> not found (benign close race)` | **[confirmed]** Self-labeled. | never |
| `ERROR …pty::stream: WebSocket receive error: … Connection reset without closing handshake` | **[confirmed]** A webview reload or pane close dropped the PTY socket. Common. | it repeats in a tight burst *and* lines up 1:1 with the user's symptom |
| `ERROR …runtime::build: Failed to load review schema validator: schemas directory not found` | **[confirmed]** The review-schema dir isn't present; non-fatal. | the report is about review comments |
| `WARN …timeline::recording: timeline flush failed; batch dropped … database is locked` | **[confirmed]** present; **[inferred]** benign in isolation — SQLite contention, the next batch succeeds. | it appears in a sustained burst — then suspect **two runtimes on one data dir** |
| `WARN …runtime::attach: attach session outbound flow overflowed beyond lossless coalescing — disconnecting` | **[confirmed]** present; **[inferred]** a pane produced output faster than the client drained it; the client reconnects and replays. | the symptom is a terminal that stopped updating |
| `WARN …shell_dispatch: orphan shell-execute reply (likely timed out)` | **[confirmed]** Self-labeled. | never |

### `atriumd.stderr.log`

| Line | Reading | Only relevant if |
|---|---|---|
| `[HOOK] Received <event> for '<adapter>': {…}` | **[confirmed]** Pure trace — roughly 90% of the file. Truncated mid-JSON by the logger; that truncation is not corruption. | you need to prove an adapter hook did or didn't fire |
| `[chat_runtime] intentional: …` | **[confirmed]** The literal word `intentional:` marks deliberate diagnostic output — **including lines whose JSON payload contains the words "failed" or "error"**. Never classify an `intentional:` line as an error by keyword. | you're reading the `outcome="…"` field on it |
| `[notes] list: body unreadable at <path> (No such file…)` | **[confirmed]**, thousands of occurrences. Deleted note bodies still in the index. | the report is about a missing note |
| `[snapshots] Interval failed: snapshot commit failed: file changed before we could read it; class=Filesystem` | **[confirmed]** A file moved mid-snapshot; retried on the next interval. | it never succeeds afterwards |
| `[fts::watcher] no enumeration entry for <path>; skipping event` | **[confirmed]** Index enumeration lag. | the report is about vault/session search |
| `[fts::extractor] timeout (Ns elapsed) — killed child for session <id>` | **[confirmed]** Bounded and intentional. | a specific session is missing from search |
| `[skills_registry::scan_scope] walk error under <path> IO error` | **[confirmed]** An unreadable dir during a skills scan. | a skill isn't showing up |
| `[timeline::git_watcher] commit read failed for <path>; skipping` | **[confirmed]** | the timeline is missing git activity |
| `[pty-reaper] killed 0 orphaned shell(s), swept N stale registry file(s)` | **[confirmed]** Periodic housekeeping. `killed 0` means nothing was wrong; a nonzero kill right after a crash is expected **cleanup**, not the cause. | |
| `[chat-runtime-reaper] killed N orphaned runtime group(s)` | **[confirmed]** Same — a large `N` at startup means the previous exit was unclean, which is a *consequence*. | |
| `[fleet-hydrate] evict <id>: persisted session does not match workspace snapshot` | **[confirmed]** Reconciliation dropping a stale entry. | the symptom is **an agent card that vanished from Activity** |
| `[harness_scan boot] added=N modified=N removed=N errors=0` | **[confirmed]** Read the `errors=` field, not the word. | `errors=` is nonzero |
| `[remote-config] fetch error (using cache): …` | **[confirmed]** Network blip; `(using cache)` is the tell. | the report is about a banner or remote setting |
| `objc[…]: Class _TtCs… is implemented in both /usr/lib/swift/… and /Applications/Xcode.app/…` | **[confirmed]** Swift-runtime duplicate-class warning from a developer toolchain. Cosmetic. | never |

### `cef.log`

| Line | Reading |
|---|---|
| `WARNING:…browser_info.cc:370] Returning a speculative frame for [n,m]` | **[confirmed]** Dominant volume; several per navigation. Never a cause. |
| `ERROR:base/mac/process_requirement.cc…] Unable to derive validation category … Code=-67030` | **[confirmed]** Chromium introspecting a code signature that isn't Chrome's. Expected in an embedded host. |
| `ERROR:sandbox/mac/system_services.cc:31] SetApplicationIsDaemon: … Code=-50` | **[confirmed]** Expected in an embedded host. |
| `ERROR:…device_event_log…] FIDO: … keychain-access-group entitlement is missing` | **[confirmed]** Touch ID / WebAuthn is unavailable inside the embedded browser. Only relevant if the user was using a passkey — in which case it *is* the answer. |
| `WARNING:…capture_device_ranking.h:255] Can't initialize the value of media.*_input.user_preference_ranking` | **[confirmed]** Device-preference defaults absent. |
| `INFO:rlz/lib/rlz_lib.cc] Attempting to send RLZ ping` | **[confirmed]** Chromium's own built-in ping — **not atrium telemetry**. Worth knowing when the report is about privacy or network traffic. |
| `WARNING:…account_consistency_mode_manager.cc] Desktop Identity Consistency cannot be enabled` | **[confirmed]** No Google OAuth client configured. Expected. |

### `daemon-signals.log`

| Line | Reading |
|---|---|
| `signal=SIGTERM(15) reason=coordinated-daemon-stop` | **[confirmed]** A normal quit. |
| `reason=transactional-update-daemon-stop` / `newer-in-place-runtime-replacement` | **[confirmed]** Normal update handoff. |
| `signal=SIGKILL(9) reason=update-daemon-stop-timeout` | **[confirmed]** present, and **not benign** — the daemon ignored SIGTERM through the grace window and was killed. Strong signal for anything update- or restore-shaped: state may have been mid-write. |

### The inverse: lines that are almost always real

| Line | Read it as |
|---|---|
| `ERROR …persistence: Failed to save metadata …: … Too many open files` | **[confirmed]** File-descriptor exhaustion (EMFILE). Layout and settings were not persisted → explains "my rooms/settings reverted". Correlates with very large workspaces. |
| `ERROR …runtime::build: Failed to initialize task store: Failed to set pragmas: database is locked` | **[confirmed]** Two runtimes contending for one data dir. A leading cause of a dead or gray app. Check `ipc/<channel>.lock`'s pid against `ps` for stray `atriumd` processes. |
| `[agent-framing] submit NOT confirmed for pane <id>: input residue still visible after 2 Enter retries` | **[confirmed]** An injected message was typed into a pane but never submitted. Near-conclusive for "I messaged an agent and nothing happened". |
| `[scheduler] card <id> fire skipped: …` | **[confirmed]** A scheduled run did not fire; the reason is inline — `agent not running: pane <id>` (the target pane is dead) vs `invalid profile: card references launch profile …` (renamed or deleted profile). |
| `[detached_launch] reconcile run <id> → <state> failed: invalid transition…` | **[confirmed]** A run-state machine rejected a transition; the run is stuck in the prior state. |
| `[chat_runtime] … failed to close sidecar work after session.start failure: … unknown session` | **[confirmed]** A chat sidecar session failed to start and its cleanup also failed. |

## Symptom → hypothesis

For each: what would confirm it, what would rule it out, and the `area:` label.

### Blank / gray window at launch — `area:daemon` or `area:ui`
- **Main process crashed before the UI mounted.** Confirm: an `atrium-desktop-*.ips` timestamped at launch, Rust panic frames. Rule out: no crash report, and `runtime.<date>.log` keeps emitting INFO after boot.
- **Two runtimes on one data dir.** Confirm: `Failed to initialize task store: … database is locked` at boot; two `atriumd` in `ps`; `ipc/<channel>.lock`'s pid not matching the live process. Rule out: one daemon, lock pid matches.
- **CEF host died.** Confirm: `atrium Helper*.ips`; `cef.log` stops abruptly. Rule out: no browser panes open.
- **Frontend crashed at the root.** Confirm: `webview-errors.ndjson` with `kind: react-root` at `T`. Rule out: no such record.
- **Decisive split:** if `boot hydration: registry hydrated from disk (… N pane(s))` appears and INFO keeps flowing afterwards, the backend is alive and this is a render-side problem.

### Rooms / panes did not come back after a restart — `area:persistence` or `area:daemon`
- **Daemon killed hard mid-write.** Confirm: `SIGKILL(9) reason=update-daemon-stop-timeout` in `daemon-signals.log` before the restart.
- **Layout was never saved.** Confirm: `ERROR …persistence: Failed to save metadata …` (especially `Too many open files`) in the *previous* session's log.
- **Restore ran but reconciled entries away.** Confirm: `boot hydration: registry hydrated from disk (… N pane(s))` with `N` far below what the user expected, plus `[fleet-hydrate] evict …` lines.
- Rule out for all three: `N` matches expectation and no evictions → the data restored and the problem is display-side.

### Terminal pane frozen, blank, or garbled — `area:pty`
- **PTY spawn/resize race.** Confirm: `pane read` shows output wrapping at 80 columns in a much wider pane.
- **Attach flow overflow.** Confirm: `attach session outbound flow overflowed … disconnecting` at `T` for that pane's shell id.
- **The process simply exited.** Confirm: `pane read` shows a returned shell prompt or an exit notice.
- Rule out: `pane list --json` still lists it and `pane read` returns *fresh* bytes on two calls a few seconds apart → the pane is alive and this is a rendering bug.

### An agent never received / never acted on a message — `area:agents`
- **The submit never landed.** Confirm: `[agent-framing] submit NOT confirmed for pane <id>`. Then check the recipient's state with `pane read` — a prompt left in a shell/bash mode, or a vi-mode keymap, changes how the injected Enter is interpreted.
- Rule out: no framing warning and `pane read` shows the message text was submitted → the agent got it and chose not to act, which is not an atrium bug.

### A scheduled or recurring task did not run — `area:tasks`
- Read the inline reason on `[scheduler] card <id> fire skipped: …`. `agent not running: pane <id>` → the bound pane died; cross-check with `pane list --json`. `invalid profile: …` → cross-check `launch-profile list --json`.
- Rule out: no `fire skipped` line at all → the schedule itself never fired; look at the card's recurrence config rather than the launch path.

### Agent-chat pane stuck, lost history, or "response interrupted" — `area:chat`
- **The sidecar died.** Confirm: `[chat-runtime-reaper] killed N orphaned runtime group(s)`, or a `session.start` whose `outcome=` is not `success`, at `T`.
- **The UI and the journal disagree.** The journal at `chat/journals/<sessionKey>.jsonl` is durable and authoritative — compare its last entries against what the user says the pane showed. A journal that has content the UI never rendered is a display bug; a journal that stops where the UI stops is a transport bug.
- Rule out: journal and UI agree and the last `session.*` call succeeded → the adapter itself ended the turn.

### Browser pane blank, media broken, or clicks do nothing — `area:browser`
- `cef.log` is the **only** place browser panes log; if it has nothing at `T`, the pane never got that far.
- **Renderer crash.** Confirm: an `atrium Helper*.ips` at `T`.
- **An overlay is eating clicks.** Symptom shape: a menu, dropdown or toast opens above a browser pane and clicking an item does nothing at all (no error anywhere). Confirm: `pane list --json` shows a `browser` pane in the room, and the user was clicking an overlay drawn over it. This leaves no log trace — the absence of evidence *is* the pattern.

### Update failed, app reverted, or macOS says the app is damaged — `area:updater`
- Read `daemon-signals.log` around the update in full. `transactional-update-daemon-stop` and `newer-in-place-runtime-replacement` are the normal handoff; `SIGKILL(9) reason=update-daemon-stop-timeout` is not.
- **Version disagreement.** Confirm: `"$CLI" version --json` `cli` differs from the version the app reports, or from the seed block's `version`.
- Rule out: a clean signal sequence and matching versions → the update completed and the problem is elsewhere.

### A model, effort, or adapter is missing from the launcher — `area:adapters`
- `"$CLI" adapter list` STATUS column first — a not-ready adapter explains itself.
- Otherwise the `script_adapter … does not match the bundled schema (continuing anyway)` WARN names the exact method and prints the rejected JSON. For this symptom that line **is** the root cause; quote it.

### Vault or session search misses a session — `area:memory-vault`
- Confirm: `[fts::extractor] timeout … for session <id>`, `[fts::watcher] no enumeration entry`, or `[timeline::backfill] … extract <id>: fts: extractor failed` naming that session.
- Rule out: no extractor line for that session id → it was never enqueued; that is a different (and more interesting) bug.

### Everything is a flat opaque grey, or a pane is unreadable over a wallpaper — `area:ui`
- This leaves **no log trace**. Ask whether a wallpaper is set (`config.json` `theme`) — the bug is invisible without one. A pane surface that stacks two translucent layers reads as a near-opaque grey box.
- This is a report where a screenshot from the user is worth more than any log; ask for one and say in the issue that you did.

### Anything else
Say so. Class the report by the subsystem the evidence points at, or use `area:unknown` and let the maintainer route it.

## `area:` labels

`area:updater`, `area:daemon`, `area:pty`, `area:browser`, `area:chat`, `area:agents`, `area:adapters`, `area:tasks`, `area:persistence`, `area:memory-vault`, `area:ui`, `area:voice`, `area:remote`, `area:cli`, `area:unknown`.

Pick one. If two genuinely apply, pick the one where the fix would land and mention the other in the body.

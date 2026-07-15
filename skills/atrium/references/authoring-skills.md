# Authoring atrium skills

Read this when the user asks you to *create a skill*, *save this as a skill*, *turn this pattern into a skill*, or *add a skill for X*. An atrium skill is a folder containing a `SKILL.md` with spec-conformant YAML frontmatter — atrium owns this convention; follow it byte-for-byte or the save fails.

## Layout

Skills live in one of two scope directories:

- **`~/.atrium/skills/<skill-name>/SKILL.md`** — user scope. Always writable.
- **`<repo>/.atrium/skills/<skill-name>/SKILL.md`** — project scope. Only valid when an atrium workspace is open.

The frontmatter `name` **must equal the parent folder name** (`code-review` → `code-review/`). Mismatches are rejected on save.

**Do NOT write to harness-owned paths** — `~/.claude/skills/`, `~/.codex/skills/`, `~/.gemini/skills/`, `~/.cursor/skills/`. atrium *reads* those (so users can author in their tool of choice) but never *writes* there. Treat them as read-only.

## Frontmatter — the byte-locked template

```yaml
---
name: <kebab-case-slug>
description: "<one or two sentences: what this skill does and when an agent should activate it>"
metadata:
  atrium-discoverable: false
  atrium-created: "<ISO-8601 UTC timestamp>"
---
```

Validator constraints (one error per failure, accumulated and surfaced inline — no short-circuit):

- `name` matches `^[a-z0-9-]{1,64}$` AND equals the parent folder name.
- `description` required, ≤ 1024 Unicode characters.
- `metadata.atrium-discoverable` is an optional boolean (default `false`). Set it to `true` to advertise the skill in eligible sessions without attaching it to an agent or launch profile.
- `metadata.atrium-created` is an ISO-8601 UTC timestamp. The in-app scaffolder fills it; hand-authoring, use the current UTC instant.
- **No top-level proprietary fields.** Anything atrium-specific lives under `metadata.atrium-*` (e.g. `metadata.atrium-tags`). The validator rejects `kind:`, `tags:`, `atrium-favorite:`, or any non-spec top-level field:

  > `Skills: validation — <top-level: atrium-foo> — top-level field not in agentskills.io spec; atrium-private fields belong under metadata.atrium-* (spec §frontmatter)`

### Discoverable skills

The standard `description` field is the activation hint. Write it so an agent can decide when the skill applies, without duplicating that guidance in atrium-specific metadata:

- `"Summarize git diffs and generate changelog entries when the user asks what changed."`
- `"Review pull requests with structured correctness, risk, and maintainability feedback."`
- `"Apply the project's React component conventions when editing TSX files."`

With `metadata.atrium-discoverable: true`:

- A user-scoped skill under `~/.atrium/skills/` is advertised in every atrium-launched session.
- A project-scoped skill under `<repo>/.atrium/skills/` is advertised only in sessions for that project.
- atrium injects only the skill name, `description`, provenance, and an `atrium skills load` command. It does not preload the `SKILL.md` body.
- An explicit agent, launch-profile, or task selection wins for the same skill identity, including an explicit `disabled` mode.
- A same-named project skill shadows the user-scoped skill in that project. This also lets a non-discoverable project definition suppress a global discoverable default.

Skills without the flag, or with it set to `false`, keep the existing opt-in behavior. Atrium-managed `metadata.atrium-*` fields (e.g. `atrium-last-used`) are written by atrium on UI interaction — don't hand-author or hand-edit them.

## Body convention

Free-form Markdown — only frontmatter is validated. The in-app scaffolder writes this skeleton; follow it unless you have reason not to:

```markdown
# <Title-Case Name>

Describe what this skill does and when the agent should activate it.

## When to use

…

## How to apply

…
```

`# Title` is the title-cased slug (`summarize-git-diff` → `Summarize Git Diff`). The two H2s are canonical: triggers / signals / phrases / file shapes under `## When to use`; step-by-step or principle guidance under `## How to apply`.

## Heavy resources go on-activation-only

Keep the SKILL.md body small and high-level. When a skill needs more than fits cleanly inline, drop bulky content into sibling subdirectories and load on demand:

- **`<skill-name>/scripts/`** — executable helpers invoked at activation time.
- **`<skill-name>/references/`** — companion Markdown pulled in on demand (a long spec, an API reference, a worked example). This very skill ships `references/notes-interactive-ui.md`, `references/capture.md`, etc. as exemplars.
- **`<skill-name>/assets/`** — non-text resources (images, fonts, fixtures).

Reference them lazily: *"read `references/long-diff-strategy.md` when the diff exceeds 500 lines"*. Discoverable skills are only advertised at SessionStart; the agent loads `SKILL.md` when the description indicates it applies. `scripts/`, `references/`, and `assets/` remain on demand after activation.

> **Propagation of atrium's own pushed content:** atrium pushes its canonical files into every install via two manifests, and an unlisted new file silently never reaches users:
> - A new **skill reference** under `references/` must be added to `skill-assets.json`'s `references` array.
> - A new **global asset or bundled skill** (anything beyond a skill's own references — e.g. another always-injected file, a new synthesis-verb skill) must be added to `canonical-assets.json` at the repo root.
>
> *Editing* an already-listed file needs no manifest change — atrium re-pushes it (hash-gated) at launch and on its periodic update cadence. Only **adding / renaming / removing** a pushed file requires a manifest edit.

## Scaffold via the in-app UI when you can

atrium ships a scaffolding modal via the workspace-sidebar Skills view's **+ New skill** button — it creates the folder, lets you opt into **Discoverable in sessions**, prefills frontmatter with a fresh `atrium-created` timestamp, writes the canonical skeleton, and opens the file. **Prefer it** — it guarantees validator parity. Fall back to writing the file directly only when the UI isn't reachable or the user explicitly asked you to author the file.

## Worked example: `summarize-git-diff`

For *"create a skill called `summarize-git-diff` that runs when I ask you to summarize a diff"*, write:

**Path:** `~/.atrium/skills/summarize-git-diff/SKILL.md`

````markdown
---
name: summarize-git-diff
description: "Summarize a git diff with a structured changelog (added / changed / removed / risk notes). Activate when the user asks to summarize a diff, review changes, or generate a changelog entry."
metadata:
  atrium-discoverable: true
  atrium-created: "2026-05-16T14:32:00Z"
---

# Summarize Git Diff

Summarize a git diff into a structured changelog grouped by impact area, with optional risk notes.

## When to use

- User pastes a diff and asks for a summary or changelog entry.
- User says "review these changes" or "what changed?".
- A CI / PR-review pane is open and the user wants a one-paragraph rollup.

## How to apply

1. Fetch the diff: `git diff <range>`
2. Group changes by impact area (frontend / backend / docs / tests / infra).
3. For each area, list: **Added**, **Changed**, **Removed**, **Risk notes** (only when non-empty).
4. End with a one-line rollup sentence.

When the diff exceeds 500 lines, read `references/long-diff-strategy.md` for the chunking convention.
````

`name` matches the folder; `description` tells the agent both what the skill does and when it applies; `atrium-discoverable` advertises it without preloading the body; `atrium-created` is a UTC instant; the body uses the canonical shape; the `references/` mention demonstrates the heavy-resources convention.

## What NOT to do

- **Don't write to `~/.claude/skills/`, `~/.codex/skills/`, `~/.gemini/skills/`, `~/.cursor/skills/`** — harness-owned. Author under `~/.atrium/skills/` (user) or `<repo>/.atrium/skills/` (project).
- **Don't add top-level fields outside the agentskills.io spec** — atrium-specific data goes under `metadata.atrium-*`.
- **Don't duplicate activation guidance in a custom metadata field** — put it in the standard `description`.
- **Don't pick a `name` that doesn't match the folder** — save fails with an inline banner.
- **Don't dump giant blocks into the body** — heavy content goes in `references/`, loaded on activation.
- **Don't hand-edit `metadata.atrium-last-used` / `atrium-favorite` or other atrium-managed fields** — clobbered on the next write.

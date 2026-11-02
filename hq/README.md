# The HQ library

Curated director personas, routines and staff templates that atrium's HQ offers when someone makes a director ("Start from…") or adds a routine ("Library"). A director also reads the library itself (`atrium hq library`) and recommends from it before writing a routine from scratch.

## Files

- `library/personas/<id>.md`, `library/routines/<id>.md`, `library/staff/<id>.md`: one bundle each. YAML frontmatter, then its long text as sections: `## Instructions` and `## Playbook` (a persona), `## Prompt` (a routine), `## Instructions` (staff). Inside `## Playbook` the playbook's own sections sit one level down (`### How I work`, `### Checklists` with `#### …` lists, `### Lessons`, `### Defaults`).
- `library.json`: the compiled document atrium reads. Never edit it by hand: run `node scripts/build-hq-library.mjs`.
- `../schemas/hq-library.schema.json`: the bundle format. atrium validates each bundle on its own and skips one it can't read, so a new field or kind never empties an older client's library.

The frontmatter is a strict YAML subset (block and flow maps and sequences, plain and quoted scalars, `#` comments). Quote a value that contains `: `, ` #`, or, inside `{ }` or `[ ]`, a comma.

## Rules

`python3 check-schemas.py` checks the schema and runs `node scripts/build-hq-library.mjs --check`, which also checks what a schema can't:

- every `{slot}` in the text is a declared param or a built-in (`{director}`, `{timezone}`), and every declared param is used;
- every routine and staff `ref` resolves, and every connector `preset` is in `connectors/catalog.json`;
- no need offers a Google `login` (`google.com`, `gmail.com` or a subdomain): Google refuses sign-in from CEF-based browsers, and the director's browser is CEF. Offer `spark` or a connector instead;
- a routine that wakes the director fires at least 15 minutes apart and at most 48 times a day, and an on-demand routine says when it's done;
- `send`, `post`, `buy` and `delete` come with `asksFirst`;
- an `autonomy` request sits on a need with a connector preset, names only effects the bundle declares, and never one that always asks first. A bundle never grants autonomy: the owner does;
- the size caps (a bundle at most 16 KB, a persona with its routines and staff at most 64 KB, a playbook at most 3,000 characters with one-line items of at most 200), and no NUL, zero-width, line-separator or bidi characters.

## Writing for it

The library is public. Write for anyone: plain, warm and brief; outcomes, not mechanics. A routine's prompt stands on its own, since a routine installs without its persona. A playbook line would help a stranger doing the job for someone else: no names, contact details, amounts or account names. Bump `revision` on any change an installed copy would want.

## Shipping

atrium compiles a snapshot of `library.json` in (`scripts/sync-hq-library.mjs` in the atrium repo) and refreshes it from this repo's `main` within the hour, so a push here reaches every client without an app release. A bundle whose `minAtrium` is newer than a client's atrium hides itself there.

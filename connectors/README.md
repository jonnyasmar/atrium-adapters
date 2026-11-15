# Connectors catalog

`catalog.json` is the curated list behind atrium's Settings > Connectors > Browse: one-click presets for MCP servers that atrium manages and mounts into agent sessions. `schemas/connectors-catalog.schema.json` defines it, and `python3 check-schemas.py` validates it, together with the cross-field rules a schema can't express (every input is declared and used, credentials come from secret inputs, auth matches the recorded evidence, pinned versions match their evidence).

Each preset is a template for the daemon's connector record (architecture contract §4). `{"input": "name"}` stands for a value the user types into the matching `inputs` entry. Secret inputs become vault references and are never stored in the definition. A header or env entry whose optional input is left empty is omitted.

## Adding a preset

1. **Pick the vendor's official server.** For a remote server, use its Streamable HTTP URL; the schema refuses deprecated `/sse` endpoints. A local server is a pinned package (npm or PyPI) or a Docker image pinned by digest. The official MCP Registry (`https://registry.modelcontextprotocol.io/v0.1/servers?search=<name>`) and the Claude plugin marketplace are good places to find candidates, but they are evidence, not sources to copy: write atrium's own description.
2. **Verify it** (next section) and choose `auth` from what the probe shows:
   - The authorization server advertises a client ID metadata document or a registration endpoint: `oauth` with `registration: "auto"`.
   - It advertises neither: `oauth` with `registration: "static"`, plus `clientId` / `clientSecret` inputs, and a `setupNote` telling the user which app to register.
   - The vendor's documented path is a token: `bearer` (or `header`), with `tokenHelpUrl` and the scopes.
   - No 401: `none`.

   `advertised.cimd` and `advertised.dcr` must match `verified.oauth`; the check fails otherwise.

   Pin `scopes` whenever the server's `scopes_supported` is broader than what agents need. When the 401 challenge names no scope, atrium asks for every scope the server lists (Gmail lists 20, including full mail access), and a preset's own `scopes` win over that list.
3. **Logo.** Use only `simple-icons` at the version in `logoSource`. From the package, copy `hex` from `data/simple-icons.json` (uppercase, with `#`) and the single path from `icons/<slug>.svg`. Skip any icon whose `data/simple-icons.json` entry has a `license` field: that icon is not CC0. Use `"logo": null` when there is no CC0 icon, and the UI shows a letter instead. If a new preset needs a newer simple-icons release, bump `logoSource.version` and recheck every logo.
4. **Tool policy.** Add `toolPolicyDefaults` (glob to `"ask"`) only for tool names you have read in the vendor's docs or source: deletes, drops, merges, arbitrary SQL, money movement. Record where you read them in `verified.toolNamesSource`. Annotation defaults (contract D16) still cover everything else.
5. **Fill `verified`** with the evidence, today's date, and plain-words `checks`. Set `status: "flagged"` with a `flagReason` when adding would fail for a reason atrium can't fix, such as a vendor that only accepts clients it has approved.
6. Set `revision: 1` and bump the catalog's `updatedAt`. Run `python3 check-schemas.py`.

When a published preset changes in a way existing connectors copy (server, inputs, tool policy), bump its `revision`.

## Verifying a preset

Verification is read-only and unauthenticated. Never send credentials, never create accounts or OAuth clients (no registration calls), and never install or run a package to check it.

- **Remote:**

  ```bash
  python3 scripts/probe-connector.py <url> --tools
  ```

  The script sends a 2026-07-28 `server/discover`, then a 2025-era `initialize`. On a 401 it follows `WWW-Authenticate` `resource_metadata` to the protected-resource metadata, then to the authorization server metadata. Copy its `mcp` and `oauth` objects into `verified`. Empty `eras` means the server refused both requests before dispatching them; the daemon learns the era after sign-in. `--tools` lists tools for servers that answer without sign-in.
- **npm:** `npm view <package> version "time[<version>]" license engines --json`. Pin the exact `latest` version.
- **PyPI:** `https://pypi.org/pypi/<package>/json` (`info.version`, the upload time, `requires_python`).
- **Docker:** resolve the tag's digest from the registry manifest (`Docker-Content-Digest`), not from a local pull.
- **Tool names** for local packages: read them from the published tarball (`npm pack <package>@<version>` into a scratch directory), without installing it.

## Official listings

`official-listings.json` (schema `schemas/connectors-listings.schema.json`) is for a vendor's official MCP server that the MCP Registry doesn't list and that isn't a preset yet. atrium shows each one as **Official**, with the vendor as its publisher, and ranks it above every third-party server named for the same product. A listing is lighter than a preset: atrium hasn't set up its sign-in or tool policy, and when atrium can't add it yet, `why` says so on its page.

The listings don't ship in the catalog. `scripts/build-registry-digest.mjs` carries them in the registry digest as `{"listing": …}` lines. A build of atrium that predates listings reads no `server` in those lines and skips them, so a listing can never break an older app. A listing's own brand (`dropbox` for `com.dropbox.mcp`) becomes a product atrium knows the owner of: another publisher's server named for it is never Official.

### Adding the next vendor

1. **Confirm it's official** from the vendor's own documentation, which must name the endpoint. A directory, a marketplace or a matching hostname alone isn't enough. Check that the MCP Registry doesn't list it under the vendor's own namespace (`https://registry.modelcontextprotocol.io/v0.1/servers?search=<name>`); if it does, atrium already tiers it and no listing is needed.
2. **Probe it:** `python3 scripts/probe-connector.py <url>`. Copy its `mcp` object, and `oauth` when there is one, into `verified`, with the vendor pages in `sources` and plain-words `checks`.
3. **Write the entry.** `server.name` is the endpoint's host reversed, then `/mcp` (`drivemcp.googleapis.com` → `com.googleapis.drivemcp/mcp`). Write atrium's own one-line description. Set `status` only when the vendor says GA, beta or preview. Add `why` only when atrium can't add it yet, as a clause that follows "atrium can't add it yet:".
4. **Vendors whose product isn't their domain's name** (Google's servers are on googleapis.com) also need an entry in `VENDORS` in atrium's `crates/atrium-connectors/src/registry/classify.rs`, so their registry servers are recognised too.
5. Bump `updatedAt`, run `python3 check-schemas.py`, then `node scripts/build-registry-digest.mjs --listings-only` to refresh the listings in the digest without crawling the registry again.

When atrium can set up the server's sign-in, promote the listing to a preset (above) and delete the listing: `check-schemas.py` refuses a listing whose endpoint a preset already has.

## Vendors: who owns which product names

`vendors.json` (schema `schemas/connectors-vendors.schema.json`) says which vendor owns which product words, and the roots it publishes from. **Official** means a vendor atrium has confirmed: a preset's publisher, a vendor in this file, or a listing's. A server is Official only when one of those published it from one of its roots and it names nothing another vendor owns. Every other publisher's server named for a vendor's word is Community, including the products of vendors atrium can't list a server for: Salesforce's servers are each customer's, and Shopify has none.

A publisher the registry proved by DNS or GitHub that isn't a vendor here is **self-published**: its server for its own product wears no badge, its page says who published it ("Published by acme.com (domain verified)"), and among servers named for a search's words it ranks above other Community servers. Adding a vendor here is what makes its servers Official.

The digest builder carries each vendor as a `{"vendor": …}` line, and the generic words as one `{"genericWords": …}` line. An app reads them on its next browse, so adding a vendor needs no app release, and builds that predate them skip them.

- **Roots** are registry namespaces of the vendor's registrable domains (`com.salesforce` for salesforce.com, `io.sonarcloud`) or `io.github.<organization>`, each with a source showing the vendor publishes from there.
- **Owned words** are distinctive names: the vendor's own name and its product trademarks. An everyday word (zoom, slack, notion) would make every server using it someone else's. Own one only after reviewing what it demotes, by replaying the index over the digest; Zoom and Slack are owned that way.
- **Endpoints** are exact URLs a vendor serves from someone else's host: a docs server on Kapa, FastMCP or a Lambda function URL. Each needs a page on the vendor's own domain that names that exact URL. A server at that endpoint counts as the vendor's; the host's other servers don't.
- **GitHub roots** need the organization domain-verified by GitHub (cite `https://api.github.com/orgs/<org>`), or a page on the vendor's own domain that links the organization or its server.
- **genericWords** are words no domain's name makes a brand ("ai", "api", "trading"). Without them, `ai.tv` existing would make every "… AI …" server someone else's. The list is a reviewed core plus every everyday word a registry domain is named for; `scripts/refresh-generic-words.py` recomputes that part from the digest. A vendor's, a listing's or a preset's word overrides it.

`check-schemas.py` holds the file to its schema. It also requires one owner per word and per root, no generic owned word, no root on a shared host, and every listing's claimed vendor word to be served from that vendor's roots.

### Adding the next vendor

1. Find the vendor's registrable domains and GitHub organization in its own docs. Cite one source per root.
2. List its name and distinctive product words. Leave out everyday words unless you've measured what they demote.
3. Run `python3 check-schemas.py`, then `node scripts/build-registry-digest.mjs --listings-only`.

After rebuilding the digest from the registry, run `python3 scripts/refresh-generic-words.py` before `--listings-only`, so new registry domains named for everyday words don't make those words brands.

The first 1,045 vendors were imported from ATR-1150's inventory of confirmed official servers, using the same rules. The importer and its report live in atrium's `claudedocs/atr-1145/`.

## Companions: a preset's vendor API and CLI

`companions.json` (schema `schemas/connectors-companions.schema.json`) gives a preset a **companion**: the vendor's REST API and CLI, which agents use through `atrium companion api|run` with a token atrium keeps as the Secrets record `companion.<id>`. It reaches what the vendor's MCP server doesn't: deletes, payouts, releases and secrets, domains. The design is atrium's `claudedocs/connector-cli-companions-2026-11/DESIGN.md`.

It is a separate file, not a preset field, because shipped apps validate `catalog.json` against a closed schema. Some things never come from this file: atrium compiles in each companion's API host, how its token is sent and the variable its CLI reads the token from. A companion id atrium doesn't know shows as "needs a newer atrium".

- **API:** atrium calls the vendor's API itself. GET and HEAD run at once; every other method waits for a person's approval. `askPaths` lists the reads that return secret values, which ask too: a path pattern (`*` within one segment), optionally with a query key that must be given (any value but empty, `false` or `0`). `noSessionPaths` lists writes whose body is the operation (GraphQL, SQL endpoints), which are never allowed for a whole session. `refusePaths` lists calls that mint or print a credential, which are refused outright.
- **CLI:** every CLI run waits for a person, so the rules here don't decide what runs. `credentialFlags` (credential flags, and flags that move where the CLI reads its settings, like `--cwd`) and `credential` rules refuse a command outright: a credential rule's single word matches only as the first subcommand word; two or more words match anywhere, in order. The other rules only choose the card's words (`exec` runs project code, `reveal` prints secrets, `write`, `read`). `valueFlags` lets atrium skip a flag's value when it finds the subcommand words.
- **Environment:** a run starts from a fixed set of the daemon's own variables, never the caller's. `env` adds constants (prompt, telemetry and update switches, pinned API hosts). `passEnv` names the caller's variables a run may keep (an account or project id). Neither may name a variable that decides which program runs, a proxy, or a companion token's. `projectEnvDeny` refuses a run when any `.env*` or `.dev.vars*` file in the directory (or its `supabase/` folder) sets one of its variables.
- **Install:** `install` and `update` hold one recipe per platform (`macos`, `linux`, `windows`). They run in a visible atrium terminal when a person clicks Install or Update, as adapter recipes do. `version.min` is the oldest version atrium runs.
- **Keeping current:** `latest` names where the newest release is listed (an npm package or a GitHub repository). `unattended: true` on an update recipe lets atrium update that CLI on its own on that platform, but only with the command built into the app, only to a release that has been out for three days, and never to a new major version. This file can turn automatic updates off; it can never change what runs or which release installs. A new companion gets automatic updates only with an app release that carries its command. Never mark a recipe that needs sudo, an installer or a downloaded script piped to a shell.
- **Skills:** each vendor skill is a `raw.githubusercontent.com` URL pinned to a commit, with its sha256. atrium fetches it on demand, checks the digest, and serves only a match. Never list a skill whose main path prints a token.

atrium's reader is strict per companion: an entry with a key the app doesn't know is left out until the app updates, so a later field can never widen what an older app lets run. Add new fields deliberately, with an app release that reads them.

### Adding a companion

1. Read the vendor's CLI source or docs for: the token variable and its precedence over a stored login; flags that take or redirect a credential (`--token`, `--api-base`); login, logout and token-printing commands; commands that run project code or print secrets; and the vendor's install and update commands per platform. Record the sources in `verified`.
2. Add the API to atrium's compiled-in table (`crates/atrium-connectors/src/companions/api.rs`) in an app release first.
3. Write the entry, then run `python3 check-schemas.py`. Then run atrium's companion tests, which hold the bundled copy to these rules.

## Shipping

The catalog is not in `canonical-assets.json` yet. The atrium consumer (`crates/atrium-managed-adapters/src/canonical_assets.rs`) accepts only the `atrium-home`, `adapter-skill`, `adapter-skill-reference` and `bundled-skill` targets. It rejects the whole manifest on an unknown target, and `atrium-home` takes only `atrium-*.md` names, whose edits are fatal at boot. Before the entry can be added:

1. The consumer must skip unknown targets instead of rejecting the manifest, and that version must ship.
2. A data target for the catalog must be added to the consumer, `scripts/generate-release-metadata.mjs` and the CI manifest check.

After that, add the entry the usual way: commit the content with its `canonical-assets.json` entry, then bump `source.generation` and run `node scripts/generate-release-metadata.mjs --write --source-commit <content commit>` in a separate metadata commit.

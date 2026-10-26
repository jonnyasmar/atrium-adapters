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

## Shipping

The catalog is not in `canonical-assets.json` yet. The atrium consumer (`crates/atrium-managed-adapters/src/canonical_assets.rs`) accepts only the `atrium-home`, `adapter-skill`, `adapter-skill-reference` and `bundled-skill` targets. It rejects the whole manifest on an unknown target, and `atrium-home` takes only `atrium-*.md` names, whose edits are fatal at boot. Before the entry can be added:

1. The consumer must skip unknown targets instead of rejecting the manifest, and that version must ship.
2. A data target for the catalog must be added to the consumer, `scripts/generate-release-metadata.mjs` and the CI manifest check.

After that, add the entry the usual way: commit the content with its `canonical-assets.json` entry, then bump `source.generation` and run `node scripts/generate-release-metadata.mjs --write --source-commit <content commit>` in a separate metadata commit.

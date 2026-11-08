# Cursor Agent local usage limitation

The SQL fixture is fully synthetic and mirrors the local message fields already read by the transcript extractor. It contains no request usage tuple. Cursor's official SDK documents per-turn usage on a live `Run` and its Team Admin API returns server-side usage events, but those are separate runtime/API surfaces, not a documented historical schema in the local `store.db` transcript. Local transcript usage therefore remains Unsupported; there is no `sessionExtractor.usage` manifest block.

Primary sources:

- https://cursor.com/docs/sdk/typescript (live per-turn usage; may be unavailable when the runtime does not report it)
- https://prod.cursor.com/docs/account/teams/admin-api (remote team usage events requiring team API access)

The fixture is invented. No Cursor account data or transcript was read.

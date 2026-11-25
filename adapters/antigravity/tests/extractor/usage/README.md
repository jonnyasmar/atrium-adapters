# Antigravity native usage

Verified locally on 2026-11-23: agy persists per-step counters in
`~/.gemini/antigravity-acp/conversations/<session>.db` (and the CLI equivalent).
The reader selects completed `steps` after a persisted integer primary-key
cursor. It decodes the usage-only fields of `CortexStepMetadata`; a missing model
name is resolved with one primary-key lookup in `gen_metadata`. That table repeats
the same counters, so it is never ingested as another request. Source trajectory
and step identity deduplicate inherited history. Pending steps hold the cursor
until their counters are final.

Input is uncached. Output includes reasoning. Native model costs were absent in
the verified sessions; the reader emits no invented dollar amount. The helper's
price table determines API-equivalent value when the model has a published rate.

Older `brain/<session>/.system_generated/logs/transcript.jsonl` files can contain
`PLANNER_RESPONSE` records with per-step counters. Only that native shape is read;
live stream events, context occupancy and session summaries are ignored.

All fixtures are invented. `native.sql` covers the verified protobuf schema.
The existing JSONL fixtures are aggregate decoys and intentionally emit nothing.
`test_database.py` checks native counters, inherited identity, pending rows,
missing-model resolution, malformed records and flat incremental work at 10× and
100× session and step history. Run:

```sh
bash adapters/antigravity/tests/extractor/usage/assert-usage.sh
python3 scripts/usage-output-version.py check antigravity
```

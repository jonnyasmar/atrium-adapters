# Antigravity native usage: Unsupported

Verified 2026-11-07 against Google's official documentation:

- [Headless mode](https://antigravity.google/docs/cli/headless) documents live
  `stream-json` `step_update` events with per-step usage and a terminal `result`
  usage summary. It does not establish those events as the durable native
  `brain/<session>/.system_generated/logs/transcript.jsonl` format.
- [ACP](https://antigravity.google/docs/cli/acp) documents a separate JSON-RPC
  transport. Headless output is not evidence of usage on that transport either.

No verified durable per-request schema was established. This is a conservative
support decision, not a claim that no Antigravity version could ever persist
usage. Do not infer calls from prose, context occupancy or result totals. The
parser intentionally ignores every row. `SYNTHETIC_AGGREGATE_DECOY` is explicitly
invented, not a documented native event.
See the [live-capture assessment](../../../../copilot/tests/extractor/usage/live-capture-assessment.md)
for the current stderr meter and prospective structured capture paths.

## Fixture contract

Every record, identifier, timestamp, model name, and count under `input/` was
invented for this test. Nothing was copied or sanitised from a real transcript.
`invented-session` exercises native-shaped content and misleading aggregates;
`invented-live-decoy` deliberately places live-only shapes in a file. That decoy
is not evidence that a harness persists those events. Even it must emit no usage.
The empty `expected-usage.jsonl` is intentional.

`--usage --batch` accepts stdin JSONL, emits exactly one checkpoint per request,
and emits no `usage` rows. `--usage --list` enumerates transcript metadata, not
usage events. Successful empty extraction does **not** mean Supported: there is
no `sessionExtractor.usage` capability, and this adapter must stay outside
`BUILT_IN_USAGE_ADAPTERS` until a request-level source is verified.

Run `bash adapters/antigravity/tests/extractor/usage/assert-usage.sh` or
`bash validate-adapter.sh adapters/antigravity`. The shared runner checks the empty
golden, every line-boundary resume, torn tails, bad CRC/truncation resets,
unreadable-file isolation, discovery, compressed input when available, and a
200-file batch budget (50 ms/file maximum). Local assertions check capability
absence, discovery IDs/metadata/`--since`, ordered complete zero-event
checkpoints with no malformed records, and an empty batch.
